#!/usr/bin/env python3
"""Builds Corenyth plan fine-tuning data (prompt -> plan JSON).

Inputs: Amazon MASSIVE en-US (CC BY 4.0; the file the Kaggle mirror
"MASSIVE - 51 languages" points to) plus generated cases MASSIVE lacks
(done/postpone/time answers/statements/hard negatives). Every prompt is
rendered exactly like Prompt._renderPlan in lib/assistant/engine.dart, so
the fine-tuned model sees what the app sends.

Usage:
  python3 -I build_dataset.py MASSIVE_en-US.jsonl OUT_DIR [--check prompt_export.json]
Writes OUT_DIR/train.jsonl and OUT_DIR/val.jsonl, rows {"prompt", "completion", "tag"}.
"""
import json
import random
import re
import sys
from datetime import datetime, timedelta

# Prompt.planSystem (plan-v1), copied verbatim from the app; --check verifies it.
PLAN_SYSTEM = "Turn the user's message into ONE JSON plan for an offline task assistant. The app reads and writes the database; you never state facts about the user's tasks.\nintent: create_task (something to do) | create_reminder (asks to be reminded/notified) | complete (says something is done) | delete | postpone (move a task later) | list (asks what is planned/pending) | recall (asks what they told you before; \"remind me to\u2026\" is create_reminder, never recall) | answer_pending (only gives the time the Pending question asked for) | cancel_pending | chat (small talk or a general question).\ntitle: the action itself, short, as the user said it, without filler like \"too\", \"also\", \"pls\", \"I have to\". For recall: what to look up.\nref: for complete/delete/postpone, the #id from Current tasks or the task's words.\nwhen: copy the user's own time words exactly (e.g. \"tomo\", \"morning 8:10\", \"in 20 min\", \"by 2h\"); never turn them into a date. Omit if none.\nrange (list only): today | tomorrow | overdue | all.\nmultiple / follow_up: only if the user asks for extra alerts or a follow-up (true) or refuses them (false).\nnegated: true if the user says not to, or is only asking or supposing.\nreply (always, at most 12 words, in the user's preferred tone): for chat, answer them. Otherwise the app confirms the action itself, so never repeat the task, times or numbers; add a short follow-up, like asking what a meeting is about.\nTones: cheerful = upbeat and warm, light exclamation; playful = witty and teasing, one fitting emoji; calm = gentle, soothing, unhurried; mature = thoughtful and composed, no slang or emoji; professional = brief, polite and formal, no emoji.\nExamples:\nI have a meeting tomorrow -> {\"intent\":\"create_task\",\"title\":\"meeting\",\"when\":\"tomorrow\",\"reply\":\"Ooh, what's the meeting about?\"}\nremind me to call mom at 5pm -> {\"intent\":\"create_reminder\",\"title\":\"call mom\",\"when\":\"at 5pm\",\"reply\":\"Want to note what to talk about?\"}\nhey how's it going -> {\"intent\":\"chat\",\"reply\":\"Doing great, thanks for asking! How's your day?\"}\nI bought the milk -> {\"intent\":\"complete\",\"ref\":\"buy milk\",\"reply\":\"Nice, one less thing to do!\"}\nwhat's on tomorrow? -> {\"intent\":\"list\",\"range\":\"tomorrow\",\"reply\":\"Here's what's coming up.\"}"

TONE_STYLES = {
    'cheerful': 'upbeat and warm, light exclamation',
    'playful': 'witty and teasing, one fitting emoji',
    'calm': 'gentle, soothing, unhurried',
    'mature': 'thoughtful and composed, no slang or emoji',
    'professional': 'brief, polite and formal, no emoji',
}
TONES = list(TONE_STYLES)
DAYS = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']
MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']


# ---------------------------------------------------------------- rendering

def personal_context(name, occupation, tone):
    parts = []
    if name and occupation:
        parts.append(f'The user is {name} and works as {occupation}.')
    elif name:
        parts.append(f'The user is {name}.')
    elif occupation:
        parts.append(f'The user works as {occupation}.')
    parts.append(f'Preferred assistant tone: {tone}.')
    return ' '.join(parts)


def render(message, now, tasks_text, tone, name='', occupation='',
           context=(), pending=None, memories=()):
    s = ('<|im_start|>system\n' + PLAN_SYSTEM + '\nAbout the user:\n'
         + personal_context(name, occupation, tone) + '<|im_end|>\n<|im_start|>user\n')
    s += f'Now: {DAYS[now.weekday()]} {now.strftime("%Y-%m-%dT%H:%M")}\n'
    if pending:
        s += f'Pending: {pending}\n'
    if memories:
        s += 'Things the user shared: ' + '; '.join(memories) + '\n'
    s += 'Current tasks:\n' + tasks_text + '\n'
    if context:
        s += '\n'.join(context) + '\n'
    s += f'Reply tone: {tone} ({TONE_STYLES[tone]})\n'
    s += f'Message: {message} /no_think<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n'
    return s


def clock(d):
    h = d.hour % 12 or 12
    return f'{h}:{d.minute:02d} {"AM" if d.hour < 12 else "PM"}'


def friendly(d, now):
    days = (d.date() - now.date()).days
    date = f'{DAYS[d.weekday()]} {d.day} {MONTHS[d.month - 1]}' + ('' if d.year == now.year else f' {d.year}')
    rel = {0: 'today', 1: 'tomorrow', -1: 'yesterday'}.get(days)
    return (f'{rel} ({date})' if rel else f'on {date}') + f' at {clock(d)}'


def task_line(tid, title, due, now):
    return f'#{tid} {title}' + (f' (due {friendly(due, now)})' if due else '')


def plan_json(intent, **f):
    out = {'intent': intent}
    for k in ['title', 'ref', 'when', 'range', 'multiple', 'follow_up', 'negated']:
        if f.get(k) is not None:
            out[k] = f[k]
    out['reply'] = f['reply']
    return json.dumps(out, ensure_ascii=False, separators=(',', ':'))


# ------------------------------------------------- reply safety (as the app)

_CI = re.IGNORECASE
WHEN_WORD = re.compile(
    r'\b(?:today|tonight|tomorrow|tmrw|yesterday|morning|afternoon|evening|noon|midnight|'
    r'week|weekend|month|monday|tuesday|wednesday|thursday|friday|saturday|sunday|'
    r'[ap]\.?m\.?|o.?clock|minutes?|mins?|hours?|hrs?|time)\b', _CI)
ACTION_CLAIM = re.compile(
    r"\b(?:i|we)(?:'ll| will)\s+(?:check|follow up|remind|notify|schedule|book|call|send)\b|"
    r"\bi(?:'ve| have|'ll| will| just| already)?\s+(?:already\s+|just\s+|now\s+|also\s+)?"
    r'(?:set|added|created|scheduled|saved|deleted|removed|completed|marked|cancell?ed|updated|'
    r'reminded|postponed|moved|rescheduled|sent|messaged|emailed|texted|called|contacted|told|'
    r'notified|booked|noted)\b|\b(?:reminders?|alerts?|alarms?|tasks?)\s+(?:is|are|has been|have been|was|were)\s+'
    r'(?:set|added|created|scheduled|saved|moved|updated|cancell?ed)\b', _CI)
GROUNDLESS = re.compile(
    r'#\d|\bdue\b|\d{4}-\d{2}-\d{2}|\breminders?\b|\btasks?\b|\btoday\b|\btomorrow\b|'
    r'\btonight\b|\bpending\b|\bnothing (?:left|due|planned)\b|\bschedule', _CI)


def safe_follow_up(line):
    return (2 <= len(line) <= 200 and '{' not in line and not re.search(r'\d', line)
            and not WHEN_WORD.search(line) and not ACTION_CLAIM.search(line))


def safe_chat(line):
    return (0 < len(line) <= 200 and '{' not in line and not re.search(r'\d', line)
            and not ACTION_CLAIM.search(line) and not GROUNDLESS.search(line))


# --------------------------------------------------------------- reply banks
# Five clearly different voices; checked against the app's filters at start.

R = {
 'event': {
  'cheerful': ["Ooh, what's it about?", "Fun! What's the occasion?", "Nice! What will it cover?", "Exciting! Anything to prepare?", "Lovely! What's it for?"],
  'playful': ["Ooh, spill the tea, what's it about? 👀", "Fancy! What's the big agenda? 😏", "Mysterious... what's it for? 🕵️", "What are we plotting? 😄", "Big plans? Tell me everything 👀"],
  'calm': ["What will it be about?", "Would you like to note what it's for?", "Is there anything you'd like to prepare?", "What is it for, if you'd like to share?", "Anything you want to keep in mind for it?"],
  'mature': ["What is the purpose of it?", "What will be discussed?", "Is there anything to prepare beforehand?", "What is it regarding?", "Shall we note its agenda?"],
  'professional': ["What is the agenda?", "Please share the topic.", "What is the subject?", "Any materials to prepare?", "What is it regarding?"]},
 'call': {
  'cheerful': ["Want to note what to talk about?", "Anything you want to remember to say?", "Hope it's a lovely chat!", "Say hi from me!", "Anything to mention on the call?"],
  'playful': ["Want a cheat sheet for the chat? 📝", "Practice your best phone voice 📞", "Gossip notes ready? 😏", "Don't forget the juicy bits 👀", "Ring ring, future you 📞"],
  'calm': ["Would you like to note what to say?", "Take it easy, it'll be a good talk.", "Anything you want to remember to mention?", "No pressure, just a friendly chat.", "Would some notes help?"],
  'mature': ["Is there anything you wish to discuss?", "Shall we note the points to cover?", "A conversation worth having.", "What would you like to raise?", "Any points to prepare?"],
  'professional': ["Any talking points to note?", "Please share any points to cover.", "Shall I note an agenda?", "Understood. Any notes for it?", "Noted. Any agenda items?"]},
 'task': {
  'cheerful': ["You've got this!", "Nice, step by step!", "Love that plan!", "Great idea!", "Happy to help you stay on track!"],
  'playful': ["Look at you being productive 😎", "Future you says thanks 🙌", "Adulting level: expert 😄", "Another quest accepted ⚔️", "Productivity mode: activated 🚀"],
  'calm': ["One thing after another.", "No rush, take it easy.", "Gently, step by step.", "You can handle this calmly.", "Breathe, it will get done."],
  'mature': ["A sensible thing to plan for.", "Good to keep that in mind.", "That is worth getting done.", "Wise to plan ahead.", "A good priority to have."],
  'professional': ["Understood.", "Acknowledged.", "Understood. Anything else?", "Very well.", "Certainly."]},
 'reminder': {
  'cheerful': ["You won't forget this one!", "Happy to help!", "Anything else on your mind?", "Easy peasy!", "Glad to keep you on track!"],
  'playful': ["Your memory's new sidekick reporting in 🦸", "Forgetting? Not on my watch 😎", "Brain backup activated 🧠", "Consider me your sticky note 📌", "Nudge incoming, eventually 😉"],
  'calm': ["Rest easy, you won't forget.", "You can let it go from your mind.", "One less thing to hold onto.", "Breathe easy.", "You can relax about this one."],
  'mature': ["That should keep things in order.", "Sensible to set that aside.", "Good to have that covered.", "A wise precaution.", "That will help you stay prepared."],
  'professional': ["Understood.", "Confirmed.", "Very well.", "Acknowledged.", "Certainly. Anything else?"]},
 'complete': {
  'cheerful': ["Nice, one less thing to do!", "Woohoo, well done!", "Great job!", "Awesome work!", "Yay, crossed off!"],
  'playful': ["Look at you, crushing it 💪", "Achievement unlocked 🏆", "Show-off 😏", "Another one bites the dust 🎉", "Okay, productivity machine 🤖"],
  'calm': ["Well done. Take a moment to enjoy it.", "Nicely done.", "That's a weight off.", "Good, you can rest a little.", "Gently done, well handled."],
  'mature': ["Well handled.", "That is good progress.", "A job well done.", "Good to have that behind you.", "Steady progress."],
  'professional': ["Well done.", "Good work.", "Thank you for the update.", "Acknowledged. Anything further?", "Excellent."]},
 'delete': {
  'cheerful': ["All cleared up!", "Fresh start!", "Nice and tidy!", "Gone, poof!", "Nice and clean!"],
  'playful': ["Poof, vanished 🪄", "Into the void it goes 🕳️", "Bye bye 👋", "Marie Kondo would approve ✨", "Clutter defeated 🧹"],
  'calm': ["A lighter list now.", "Let it go, that's fine.", "Less to carry.", "Clear and simple.", "A little more space."],
  'mature': ["Sensible to let that go.", "Good to clear what no longer matters.", "A cleaner plan.", "That simplifies things.", "Fair enough."],
  'professional': ["Understood.", "Acknowledged.", "Very well.", "Certainly.", "Understood. Anything else?"]},
 'postpone': {
  'cheerful': ["No worries, plenty of room!", "All good, take your easy pace!", "Flexibility is great!", "Sounds like a plan!", "No stress!"],
  'playful': ["Procrastination, but organized 😏", "Snooze button pressed 😴", "Future you's problem now 😜", "Fashionably late, I see 🕶️", "Kicking the can, nicely 🥫"],
  'calm': ["That's okay, no rush.", "Give yourself the space.", "It can wait a little.", "Easy does it.", "Plenty of room to breathe."],
  'mature': ["A reasonable adjustment.", "Better to plan realistically.", "Sensible to shift it.", "Good to adjust when needed.", "Fair adjustment."],
  'professional': ["Understood.", "Acknowledged.", "Very well.", "Certainly.", "Understood. Anything else?"]},
 'list': {
  'cheerful': ["Here's what's coming up!", "Let's take a look!", "Here you go!", "Here's your lineup!", "Here's the plan!"],
  'playful': ["Drumroll please 🥁", "Behold, your agenda 📜", "Brace yourself 😅", "The list awaits 👀", "Let's see the damage 😬"],
  'calm': ["Here's what you have.", "Let's look at it together.", "Here it is, one by one.", "Take a look, no rush.", "Here's the overview."],
  'mature': ["Here is what lies ahead.", "Here is your overview.", "This is what you have planned.", "Here is the current picture.", "Here is the summary."],
  'professional': ["Here is your list.", "Please find your items below.", "Here is the overview.", "Listed below.", "Here are the details."]},
 'recall': {
  'cheerful': ["Let me see what you told me!", "Ooh, let me look!", "Checking my notes!", "Let's find it!", "One sec, looking!"],
  'playful': ["Digging through my memory vault 🗄️", "Elephant memory, engage 🐘", "Let me check my diary 📔", "Rummaging through notes 🔍", "Memory lane, here we go 🛣️"],
  'calm': ["Let me look at what you shared.", "Let's see what you told me.", "Here's what I have.", "Let me gently check.", "Let's look back together."],
  'mature': ["Here is what you shared earlier.", "Let me recall what you said.", "Here is what I have on record.", "Allow me to look.", "Here is what I remember."],
  'professional': ["Retrieving your notes.", "Here is the stored information.", "Searching saved notes.", "Here is what is on record.", "Checking records."]},
 'answer': {
  'cheerful': ["Perfect, thanks!", "Great, got it!", "Awesome, thank you!", "Lovely!", "Super!"],
  'playful': ["Locked in 🔒", "Bam, sorted 💥", "Gotcha 😎", "Noted, boss 🫡", "Sweet 🍭"],
  'calm': ["Thank you, that's settled.", "Alright, all set.", "Good, that's clear now.", "Thanks, that helps.", "Okay, settled."],
  'mature': ["Thank you, that is clear.", "Very well, that works.", "Good, that settles it.", "That works well.", "Understood, thank you."],
  'professional': ["Thank you.", "Understood.", "Confirmed.", "Noted, thank you.", "Very well."]},
 'cancel_pending': {
  'cheerful': ["No problem, dropped it!", "All good, forget it!", "Sure thing, it's gone!", "No worries at all!", "Okay, scratch that!"],
  'playful': ["Abort mission 🚫", "Never happened 🤫", "Poof, forgotten 🪄", "Okay, okay, dropping it 🙃", "Consider it vaporized 💨"],
  'calm': ["That's fine, let it go.", "No problem at all.", "Alright, we'll leave it.", "Okay, no need to worry.", "That's okay."],
  'mature': ["Very well, we will leave it.", "Understood, let us set it aside.", "That is fine.", "Fair enough.", "As you wish."],
  'professional': ["Understood. Cancelled.", "Acknowledged.", "Very well.", "Request withdrawn.", "Understood."]},
 'negated': {
  'cheerful': ["Okay, no problem!", "Got it, nothing then!", "Sure, I'll leave it!", "All good!", "No worries!"],
  'playful': ["Fine, I'll pretend I didn't hear 🙈", "Zipping my lips 🤐", "Hands off, got it 🙌", "Okay, chill mode 😎", "Copy that, doing nothing 😴"],
  'calm': ["Alright, I'll leave it.", "That's fine.", "Okay, nothing to do.", "No problem.", "Understood, leaving it be."],
  'mature': ["Understood, I will leave it.", "Very well.", "As you prefer.", "Fair enough.", "Noted, nothing further."],
  'professional': ["Understood.", "Acknowledged.", "Very well.", "No action taken.", "Certainly."]},
}

CHAT = {
 'greet': {
  'cheerful': ["Doing great, thanks for asking! How are you?", "Hi there! What's on your mind?", "Hello! Lovely to hear from you!", "Hey! How's everything going?", "Hi! Ready when you are!"],
  'playful': ["Hey you 👋 What trouble are we planning?", "Oh hi! Missed me? 😏", "Yo! What's cooking? 🍳", "Hello, human friend 🤖", "Hey hey! What's the scoop? 👀"],
  'calm': ["Hello. How are you feeling?", "Hi there. I'm here whenever you need.", "Hello. Take your pace, I'm listening.", "Hi. How has your day been?", "Hello. What's on your mind?"],
  'mature': ["Hello. How have you been?", "Good to hear from you.", "Hello. How can I be of help?", "Hello. I hope all is well.", "Greetings. What is on your mind?"],
  'professional': ["Hello. How may I assist you?", "Good day. How can I help?", "Hello. What do you need?", "Hello. Ready to assist.", "Greetings. How may I help?"]},
 'thanks': {
  'cheerful': ["You're so welcome!", "Anytime, happy to help!", "Glad I could help!", "My pleasure!", "Yay, glad that helped!"],
  'playful': ["Anytime, I accept payment in compliments 😌", "No biggie, I'm kind of great 😎", "You owe me a virtual cookie 🍪", "All in a day's work 🦸", "Aw, stop it 😊"],
  'calm': ["You're welcome. Take care.", "Glad it helped.", "Anytime. I'm here.", "You're welcome, rest easy.", "Happy to help, gently."],
  'mature': ["You are welcome.", "Glad to be of help.", "It was my pleasure.", "Happy to assist.", "Always glad to help."],
  'professional': ["You're welcome.", "My pleasure.", "Glad to assist.", "Certainly.", "Anytime."]},
 'joke': {
  'cheerful': ["Why did the scarecrow win an award? He was outstanding in his field!", "What do you call a sleeping bull? A bulldozer!", "Why don't eggs tell jokes? They'd crack up!", "What do you call fake spaghetti? An impasta!", "Why did the bicycle fall over? It was two tired!"],
  'playful': ["Why don't skeletons fight? No guts 💀", "I'd tell you a chemistry joke, but no reaction 🧪", "Parallel lines have so much in common. Shame they'll never meet 😅", "I'm reading a book on anti-gravity. Can't put it down 📚", "Why did the coffee file a police report? It got mugged ☕"],
  'calm': ["Why did the cloud stay calm? It knew how to go with the flow.", "What did the ocean say to the shore? Nothing, it just waved.", "Why do bees hum? They forgot the words.", "What's a tree's favorite drink? Root beer.", "Why did the leaf relax? It was finally off the hook."],
  'mature': ["I used to be a banker, but I lost interest.", "Time flies like an arrow; fruit flies like a banana.", "A word to the wise is unnecessary.", "Never trust atoms; they make up everything.", "History repeats itself, which is why I rarely ask it twice."],
  'professional': ["Why did the spreadsheet go to therapy? Too many cells.", "Why was the manager calm? Excellent delegation.", "I would tell a networking joke, but it lacks connections.", "Why do accountants love winter? Ice ledgers.", "Meetings: where minutes are kept and hours are lost."]},
 'quirky': {
  'cheerful': ["Ha, that's a fun one!", "Ooh, interesting! Tell me more?", "Love that energy!", "That made me smile!", "Ha! You're full of surprises!"],
  'playful': ["Ha, plot twist 😄", "You're weird. I like it 😜", "Bold question, bolder human 😏", "Hmm, my circuits are intrigued 🤖", "Ooh, spicy question 🌶️"],
  'calm': ["That's an interesting thought.", "Hmm, tell me more if you like.", "I hear you.", "That's alright, I'm listening.", "Interesting. How do you feel about it?"],
  'mature': ["An interesting thought.", "That is worth considering.", "Fair point.", "Interesting perspective.", "I understand."],
  'professional': ["Understood.", "Interesting point.", "Noted.", "I see.", "Thank you for sharing."]},
 'offline': {
  'cheerful': ["I can't look that up offline, sorry!", "Oops, I can't check that without internet!", "I wish I could look that up, but I'm offline!", "That's outside what I can check offline!", "No internet for me, sorry about that!"],
  'playful': ["No Wi-Fi in my brain, sadly 📵", "I'd google it, but I'm offline 😅", "My crystal ball needs internet 🔮", "Offline life, can't check that 🏝️", "That's above my offline pay grade 😬"],
  'calm': ["I can't look that up offline, I'm afraid.", "That's something I can't check from here.", "I'd rather not guess on that one.", "I can't access that offline.", "I can't check that, sorry."],
  'mature': ["I cannot look that up offline.", "That is beyond what I can verify offline.", "I would rather not guess at that.", "I have no way to check that offline.", "That information is out of my reach offline."],
  'professional': ["I cannot access that offline.", "That information is unavailable offline.", "I am unable to look that up.", "Not available offline.", "I cannot verify that offline."]},
 'cant': {
  'cheerful': ["I can't do that one, but I'm happy to help you plan!", "That's not something I can do, sorry!", "Oops, that's outside my skills!", "I can't do that here, but I can help you plan it!", "Not my thing, sadly! Anything to plan?"],
  'playful': ["I'm a planner, not a magician 🪄", "My arms are too short for that 🦖", "Nope, that's above my skill tree 🌳", "I wish! I'm just a humble planner 😅", "Can't do that, but I can nag you about it 😜"],
  'calm': ["I can't do that here, but I can help you plan.", "That's outside what I can do, I'm sorry.", "I'm not able to do that.", "I can't help with that one.", "That's beyond me, but I'm here to help plan."],
  'mature': ["That is outside what I can do.", "I am not able to do that here.", "I cannot do that, but I can help you plan.", "That is beyond my abilities.", "I am afraid I cannot help with that."],
  'professional': ["That action is not supported.", "I am unable to perform that action.", "Not supported. I can help with planning.", "That is outside my capabilities.", "Unsupported request."]},
 'feeling': {
  'cheerful': ["Aw, sending you a big hug!", "You've got this, I believe in you!", "That sounds tough, hang in there!", "Yay, love to hear that!", "I'm here for you!"],
  'playful': ["Virtual hug incoming 🤗", "Want me to cheer louder? 📣", "Ugh, rough. Snack break? 🍫", "Look at you, glowing ✨", "Feelings detected, hugs deployed 🤗"],
  'calm': ["Take a slow breath. I'm here.", "That's okay. Be gentle with yourself.", "It's alright to feel that way.", "Rest a little if you can.", "I'm glad you shared that."],
  'mature': ["That sounds understandable.", "It is fine to feel that way.", "Thank you for sharing that.", "Take care of yourself.", "That is worth acknowledging."],
  'professional': ["Thank you for sharing.", "Understood. Take care.", "Noted. Please take care.", "I appreciate you telling me.", "Understood."]},
}


def check_banks():
    for cat, by in R.items():
        for tone, lines in by.items():
            for l in lines:
                assert safe_follow_up(l), (cat, tone, l)
    for cat, by in CHAT.items():
        for tone, lines in by.items():
            for l in lines:
                assert safe_chat(l), (cat, tone, l)


# ----------------------------------------------------------------- vocab

NAMES = ['Kabir', 'Asha', 'Ravi', 'Priya', 'Mum', 'Dad', 'John', 'Sara', 'Aditya', 'Meera', 'Tom', 'Neha', 'Arjun', 'Lisa', 'the landlord', 'my boss']
EVENTS = ['meeting', 'dentist appointment', 'doctor appointment', 'interview', 'party', 'presentation', 'team standup', 'client call', 'exam',
          'birthday dinner', 'parent teacher meeting', 'gym session', 'haircut', 'yoga class', 'flight', 'wedding', 'review meeting', 'date']
ACTIONS = [('call {p}', 'called {p}'), ('buy milk', 'bought the milk'), ('pay the electricity bill', 'paid the electricity bill'),
           ('send the report', 'sent the report'), ('water the plants', 'watered the plants'), ('book train tickets', 'booked the train tickets'),
           ('email {p}', 'emailed {p}'), ('clean my room', 'cleaned my room'), ('renew my passport', 'renewed my passport'),
           ('submit the assignment', 'submitted the assignment'), ('pick up the laundry', 'picked up the laundry'), ('fix the bike', 'fixed the bike'),
           ('return the library books', 'returned the library books'), ('buy a gift for {p}', 'bought the gift for {p}'),
           ('wash the car', 'washed the car'), ('review the slides', 'reviewed the slides'), ('take my vitamins', 'took my vitamins'),
           ('feed the cat', 'fed the cat'), ('order groceries', 'ordered the groceries'), ('text {p}', 'texted {p}'),
           ('finish the essay', 'finished the essay'), ('book a dentist appointment', 'booked the dentist appointment'),
           ('pay rent', 'paid rent'), ('charge my phone', 'charged my phone'), ('call the bank', 'called the bank')]
DAY_WORDS = ['today', 'tomorrow', 'tomo', 'tmrw', 'tonight', 'on Friday', 'on Monday', 'this Saturday', 'on Sunday', 'this evening',
             'tomorrow morning', 'tomorrow evening', 'on Wednesday', 'on 5 November', 'on Thursday']
TIME_WORDS = ['at 5pm', 'at 10am', 'at 7:30', 'at 6 pm', 'at noon', 'at 9', 'around 4', 'at 3:15pm', 'at 8 in the morning', 'at 11']
REL_WORDS = ['in 20 minutes', 'in 2 hours', 'in half an hour', 'in 10 mins', 'in an hour']
DURATIONS = ['by 30 minutes', 'by 1 hour', 'by 2 hours', 'by a day', 'by 15 mins', 'by an hour']
LATER = ['to tomorrow', 'to Friday', 'to 6pm', 'to next week', 'to the evening', 'till Monday']
PROFILES = [('', ''), ('Souvik', 'developer'), ('Asha', 'teacher'), ('Ravi', ''), ('', 'student'), ('Meera', 'nurse'),
            ('Arjun', 'designer'), ('Lisa', 'manager'), ('Tom', ''), ('Neha', 'doctor')]
MEMORIES = ['User prefers evening calls', 'Kabir is my brother', 'User likes tea', 'Priya works at the bank', 'User is vegetarian']


def fill(s, rng):
    return s.replace('{p}', rng.choice(NAMES))


def when_phrase(rng):
    r = rng.random()
    if r < 0.4:
        return rng.choice(DAY_WORDS)
    if r < 0.7:
        return f'{rng.choice(DAY_WORDS)} {rng.choice(TIME_WORDS)}'
    if r < 0.85:
        return rng.choice(TIME_WORDS)
    return rng.choice(REL_WORDS)


def maybe_cap(s, rng):
    s = s.strip()
    if rng.random() < 0.5:
        s = s[:1].upper() + s[1:]
    if rng.random() < 0.15:
        s += rng.choice(['.', '!', ' pls', ' please'])
    return s


# ------------------------------------------------------------- the context

class Scene:
    """Random but realistic app state around one message."""

    def __init__(self, rng):
        self.rng = rng
        self.now = datetime(2026, 1, 1, 7, 0) + timedelta(days=rng.randrange(330), minutes=rng.randrange(16 * 60))
        self.tone = rng.choice(TONES)
        self.name, self.occ = rng.choice(PROFILES)
        self.tasks = []  # (id, title, due)
        self.next_id = rng.randrange(1, 30)
        self.context = []
        self.pending = None
        self.memories = [rng.choice(MEMORIES)] if rng.random() < 0.1 else []
        for _ in range(rng.choice([0, 0, 1, 2, 3, 4, 5])):
            self.add(fill(rng.choice(ACTIONS + [(e, '') for e in EVENTS])[0], rng))

    def add(self, title, due=None):
        if due is None and self.rng.random() < 0.4:
            due = self.now.replace(minute=0) + timedelta(hours=self.rng.randrange(1, 72))
        tid = self.next_id
        self.next_id += self.rng.randrange(1, 4)
        self.tasks.append((tid, title, due))
        return tid

    def prompt(self, message):
        if self.rng.random() < 0.25 and self.tasks:
            t = self.rng.choice(self.tasks)
            self.context.insert(0, 'Last task mentioned: ' + task_line(t[0], t[1], t[2], self.now))
        tasks = sorted(self.tasks)
        text = '\n'.join(task_line(i, t, d, self.now) for i, t, d in tasks) if tasks else '(none)'
        return render(message, self.now, text, self.tone, self.name, self.occ,
                      self.context, self.pending, self.memories)


def row(scene, message, completion, tag):
    return {'prompt': scene.prompt(message), 'completion': completion + '<|im_end|>', 'tag': tag}


# --------------------------------------------------------------- MASSIVE

SLOT = re.compile(r'\[(\w+) : ([^\]]+)\]')
TIME_SLOTS = {'date', 'time', 'timeofday', 'general_frequency'}
PREP = {'at', 'on', 'in', 'by', 'around', 'before', 'after', 'for', 'this', 'next', 'every'}
WAKE = re.compile(r'^(?:olly|alexa|hey olly|ok google|google)[, ]+', _CI)


def spans(annot):
    """(clean text, [(slot, value, start, end)]) from an annot_utt."""
    out, text, pos = [], '', 0
    for m in SLOT.finditer(annot):
        text += annot[pos:m.start()]
        start = len(text)
        text += m.group(2)
        out.append((m.group(1), m.group(2), start, len(text)))
        pos = m.end()
    text += annot[pos:]
    return text, out


def time_words(text, sl):
    """The user's time words: each time slot with its preposition, in order."""
    ts = [s for s in sl if s[0] in TIME_SLOTS]
    if not ts:
        return None, text
    pieces, cuts = [], []
    for _, value, a, b in ts:
        before = text[:a].rstrip().split(' ')
        if before and before[-1] in PREP:
            a = len(text[:a].rstrip()) - len(before[-1])
        pieces.append(text[a:b].strip())
        cuts.append((a, b))
    rest, pos = '', 0
    for a, b in cuts:
        rest += text[pos:a]
        pos = b
    rest += text[pos:]
    return ' '.join(pieces), re.sub(r'\s+', ' ', rest).strip()


BLOCK = re.compile(r'\b(?:porn\w*|sex\w*|dildo|naked|nude|fuck\w*|shit\w*|bitch\w*|dick|ass|kill\w*|drugs?|weed|suicide|die)\b', _CI)
FILLER = re.compile(r"^(?:please |pls |can you |could you |would you |will you |i need you to |i want you to )+", _CI)
REMIND = re.compile(r'\b(?:remind|reminder|notif\w*|alert|alarm|ping|nudge|don\'t let me forget)\b', _CI)


def convert_massive(path, rng):
    rows_in = [json.loads(l) for l in open(path, encoding='utf-8')]
    rng.shuffle(rows_in)
    out, caps = [], {'calendar_set': 1000, 'calendar_query': 420, 'calendar_remove': 300, 'lists': 420,
                     'alarm': 180, 'chat': 300, 'quirky': 160, 'offline': 260, 'cant': 220}
    count = {k: 0 for k in caps}

    def take(k):
        if count[k] >= caps[k]:
            return False
        count[k] += 1
        return True

    for r in rows_in:
        intent = r['intent']
        annot = WAKE.sub('', r['annot_utt'])
        text, sl = spans(annot)
        text = WAKE.sub('', text).strip()
        if len(text) < 3 or BLOCK.search(text):
            continue
        sc = Scene(rng)
        tone = sc.tone
        slot = {s[0]: s[1] for s in sl}
        msg = maybe_cap(text, rng)
        when, rest = time_words(text, sl)

        if intent == 'calendar_set':
            title = None
            m = re.search(r'\bremind (?:me|us) (?:to|that|about|of) (.+)$', rest, _CI)
            if m:
                title = FILLER.sub('', m.group(1)).strip(' .')
            elif 'event_name' in slot:
                ev = slot['event_name']
                person = slot.get('person')
                title = f'{ev} with {person}' if person and f'{ev} with {person}' in text else ev
            if (not title or len(title.split()) > 6 or len(title) < 3 or re.search(r'\bthing\b', title, _CI)
                    or re.match(r'^(?:when|what|which|is|are|do|does|did|how|where|who|can i|should)\b', text, _CI)):
                continue
            reminder = bool(REMIND.search(text))
            if not take('calendar_set'):
                continue
            ev_like = any(w in title.lower() for w in ['meeting', 'appointment', 'party', 'interview', 'dinner', 'lunch', 'class', 'game', 'wedding', 'event', 'conference', 'birthday', 'concert'])
            cat = 'call' if title.lower().startswith('call') else 'event' if ev_like else ('reminder' if reminder else 'task')
            out.append(row(sc, msg, plan_json('create_reminder' if reminder else 'create_task',
                                              title=title, when=when, reply=rng.choice(R[cat][tone])), 'm:calendar_set'))
        elif intent in ('calendar_query', 'alarm_query', 'lists_query'):
            if (not re.search(r'\b(?:what|which|any|anything|show|list|tell me|upcoming|do i have|is there|check|read)\b', text, _CI)
                    or re.search(r'\bmake a list\b', text, _CI)):
                continue
            if 'person' in slot and intent == 'calendar_query' and re.search(r'\bcall|email|text\b', text, _CI):
                continue
            d = (slot.get('date') or '').lower()
            rg = 'today' if d == 'today' else 'tomorrow' if d == 'tomorrow' else 'all'
            if not take('calendar_query'):
                continue
            out.append(row(sc, msg, plan_json('list', range=rg, reply=rng.choice(R['list'][tone])), 'm:' + intent))
        elif intent in ('calendar_remove', 'lists_remove'):
            target = slot.get('event_name')
            if intent == 'lists_remove':
                m = re.search(r'\b(?:remove|delete|take|cross off|erase)\s+(.+?)\s+(?:from|off)\b', text, _CI)
                target = m.group(1) if m and len(m.group(1).split()) <= 4 else None
            if (not target or re.search(r'\b(?:all|everything|every)\b', text, _CI)
                    or re.match(r'^(?:the |an? )?(?:list|item|items|events?|it|that|everything)$', target, _CI)):
                continue
            if not take('calendar_remove'):
                continue
            tid = sc.add(target)
            rng.shuffle(sc.tasks)
            out.append(row(sc, msg, plan_json('delete', ref=f'#{tid}', reply=rng.choice(R['delete'][tone])), 'm:' + intent))
        elif intent == 'lists_createoradd':
            m = re.search(r'\b(?:add|put|include|insert)\s+(.+?)\s+(?:to|on|in|into)\s+(?:my |the |a )?(?:\w+ )?(?:list|to do|to-do)\b', text, _CI)
            if not m or len(m.group(1).split()) > 5:
                continue
            if not take('lists'):
                continue
            out.append(row(sc, msg, plan_json('create_task', title=m.group(1), reply=rng.choice(R['task'][tone])), 'm:lists_add'))
        elif intent == 'alarm_set':
            if not re.search(r'\bwake me\b', text, _CI) or not take('alarm'):
                continue
            out.append(row(sc, msg, plan_json('create_reminder', title='wake up', when=when,
                                              reply=rng.choice(R['reminder'][tone])), 'm:alarm_set'))
        elif intent in ('general_greet', 'general_joke', 'general_quirky'):
            if intent == 'general_quirky' and (
                    re.search(r'\b(?:busy|calendar|schedule|remind|meeting|appointment|event|alarm|list|porn|sex|kill|drugs?)\b', text, _CI)
                    or not take('quirky')):
                continue
            if not take('chat'):
                continue
            cat = {'general_greet': 'greet', 'general_joke': 'joke'}.get(intent, 'quirky')
            out.append(row(sc, msg, plan_json('chat', reply=rng.choice(CHAT[cat][tone])), 'm:' + intent))
        elif intent.split('_')[0] in ('qa', 'weather', 'news') or intent in ('datetime_convert', 'recommendation_events', 'recommendation_locations', 'recommendation_movies', 'cooking_recipe'):
            if not take('offline'):
                continue
            out.append(row(sc, msg, plan_json('chat', reply=rng.choice(CHAT['offline'][tone])), 'm:offline'))
        elif intent.split('_')[0] in ('email', 'social', 'play', 'music', 'iot', 'transport', 'takeaway', 'audio'):
            if REMIND.search(text) or not take('cant'):
                continue
            out.append(row(sc, msg, plan_json('chat', reply=rng.choice(CHAT['cant'][tone])), 'm:cant'))
    return out


# -------------------------------------------------------------- generated

def generated(rng, n):
    out = []
    makers = [
        (14, gen_statement), (12, gen_remind), (9, gen_add), (12, gen_complete), (8, gen_postpone),
        (5, gen_delete), (6, gen_list), (5, gen_recall), (6, gen_answer), (3, gen_cancel_pending),
        (6, gen_greet), (4, gen_thanks), (4, gen_feeling), (3, gen_negated), (4, gen_add_hard_negative),
    ]
    total = sum(w for w, _ in makers)
    for w, f in makers:
        for _ in range(round(n * w / total)):
            r = f(rng)
            if r:
                out.append(r)
    return out


def gen_statement(rng):
    sc = Scene(rng)
    ev = rng.choice(EVENTS)
    if rng.random() < 0.3:
        ev = f'{ev} with {rng.choice(NAMES)}'
    w = rng.choice(DAY_WORDS) if rng.random() < 0.6 else when_phrase(rng)
    msg = rng.choice(['I have a {e} {w}', "I've got a {e} {w}", 'there is a {e} {w}', 'got a {e} {w}', 'I have {e} {w}',
                      '{w} I have a {e}', 'my {e} is {w}']).format(e=ev, w=w)
    return row(sc, maybe_cap(msg, rng), plan_json('create_task', title=ev, when=w, reply=rng.choice(R['event'][sc.tone])), 'g:statement')


def gen_remind(rng):
    sc = Scene(rng)
    act = fill(rng.choice(ACTIONS)[0], rng)
    w = when_phrase(rng) if rng.random() < 0.85 else None
    forms = ['remind me to {a} {w}', 'can you remind me to {a} {w}', 'pls remind me {w} to {a}', "don't let me forget to {a} {w}",
             'remind me {w} to {a}', 'set a reminder to {a} {w}', 'could u remind me to {a} {w}'] if w else \
            ['remind me to {a}', 'can you remind me to {a}', 'set a reminder to {a}']
    msg = rng.choice(forms).format(a=act, w=w or '').strip()
    cat = 'call' if act.startswith(('call', 'text', 'email')) else 'reminder'
    return row(sc, maybe_cap(msg, rng), plan_json('create_reminder', title=act, when=w, reply=rng.choice(R[cat][sc.tone])), 'g:remind')


def gen_add(rng):
    sc = Scene(rng)
    act = fill(rng.choice(ACTIONS)[0], rng)
    w = when_phrase(rng) if rng.random() < 0.3 else None
    msg = rng.choice(['add a task to {a}', 'add {a} to my list', 'I need to {a}', 'put {a} on my to-do list', 'new task: {a}',
                      'I have to {a}', 'note down {a}', 'add task {a}']).format(a=act)
    if w:
        msg += ' ' + w
    return row(sc, maybe_cap(msg, rng), plan_json('create_task', title=act, when=w, reply=rng.choice(R['task'][sc.tone])), 'g:add')


def gen_add_hard_negative(rng):
    """The same words as an open task, but the user asks to add: never complete."""
    sc = Scene(rng)
    act = fill(rng.choice(ACTIONS)[0], rng)
    sc.add(act)
    msg = rng.choice(['add a task to {a}', 'add {a} again', 'add another task to {a}', 'remind me to {a} again']).format(a=act)
    intent = 'create_reminder' if msg.startswith('remind') else 'create_task'
    return row(sc, maybe_cap(msg, rng), plan_json(intent, title=act, reply=rng.choice(R['task'][sc.tone])), 'g:add_negative')


def gen_complete(rng):
    sc = Scene(rng)
    name = rng.choice(NAMES)
    act, past = (s.replace('{p}', name) for s in rng.choice(ACTIONS))
    tid = sc.add(act)
    rng.shuffle(sc.tasks)
    msg = rng.choice(["I've {past}", 'I {past}', 'done with {act}', 'finished {act}', 'mark {act} as done', '{act} is done',
                      'just {past}', 'ok {past}', 'completed {act}', "I've {past} finally"]).format(past=past, act=act)
    return row(sc, maybe_cap(msg, rng), plan_json('complete', ref=f'#{tid}', reply=rng.choice(R['complete'][sc.tone])), 'g:complete')


def gen_postpone(rng):
    sc = Scene(rng)
    act = fill(rng.choice(ACTIONS)[0], rng)
    tid = sc.add(act, sc.now.replace(minute=0) + timedelta(hours=rng.randrange(1, 30)))
    rng.shuffle(sc.tasks)
    if rng.random() < 0.6:
        w = rng.choice(DURATIONS)
        msg = rng.choice(['postpone {a} {w}', 'push {a} back {w}', 'delay {a} {w}', 'move {a} later {w}', 'snooze {a} {w}']).format(a=act, w=w)
    else:
        w = rng.choice(LATER)
        msg = rng.choice(['move {a} {w}', 'push {a} {w}', 'reschedule {a} {w}', 'postpone {a} {w}']).format(a=act, w=w)
    return row(sc, maybe_cap(msg, rng), plan_json('postpone', ref=f'#{tid}', when=w, reply=rng.choice(R['postpone'][sc.tone])), 'g:postpone')


def gen_delete(rng):
    sc = Scene(rng)
    act = fill(rng.choice(ACTIONS + [(e, '') for e in EVENTS])[0], rng)
    tid = sc.add(act)
    rng.shuffle(sc.tasks)
    msg = rng.choice(['delete {a}', 'remove {a} from my list', 'cancel {a}', 'get rid of the {a} task', 'drop {a}', 'remove the task {a}']).format(a=act)
    return row(sc, maybe_cap(msg, rng), plan_json('delete', ref=f'#{tid}', reply=rng.choice(R['delete'][sc.tone])), 'g:delete')


def gen_list(rng):
    sc = Scene(rng)
    rg, msg = rng.choice([
        ('tomorrow', "what's on tomorrow?"), ('tomorrow', 'what do I have tomorrow'), ('today', 'what do I have today'),
        ('today', "what's on my plate today?"), ('all', 'show my tasks'), ('all', "what's pending?"), ('all', 'list my reminders'),
        ('overdue', 'anything overdue?'), ('overdue', 'what did I miss'), ('all', 'what do I need to do'),
        ('tomorrow', 'anything due tmrw?'), ('today', 'whats left for today'), ('all', 'show me everything')])
    return row(sc, maybe_cap(msg, rng), plan_json('list', range=rg, reply=rng.choice(R['list'][sc.tone])), 'g:list')


def gen_recall(rng):
    sc = Scene(rng)
    who = rng.choice(['Kabir', 'Priya', 'my brother', 'my boss', 'Ravi', 'my diet', 'my landlord'])
    msg = rng.choice(['what did I tell you about {w}', 'do you remember what I said about {w}', 'what do you know about {w}',
                      'remind me what I told you about {w}', 'what did I say about {w}?']).format(w=who)
    return row(sc, maybe_cap(msg, rng), plan_json('recall', title=who, reply=rng.choice(R['recall'][sc.tone])), 'g:recall')


def gen_answer(rng):
    sc = Scene(rng)
    title = rng.choice([fill(a[0], rng) for a in ACTIONS] + EVENTS)
    sc.pending = f'{rng.choice(["task", "reminder"])} "{title}" still needs a time'
    w = rng.choice(TIME_WORDS + ['5pm', '10am', 'tomorrow at 9', '7:30', 'around 6 in the evening', 'noon', 'tonight at 8'])
    return row(sc, maybe_cap(w, rng), plan_json('answer_pending', when=w, reply=rng.choice(R['answer'][sc.tone])), 'g:answer')


def gen_cancel_pending(rng):
    sc = Scene(rng)
    sc.pending = f'reminder "{fill(rng.choice(ACTIONS)[0], rng)}" still needs a time'
    msg = rng.choice(['never mind', 'forget it', 'cancel that', 'nah leave it', 'no need', 'skip it'])
    return row(sc, maybe_cap(msg, rng), plan_json('cancel_pending', reply=rng.choice(R['cancel_pending'][sc.tone])), 'g:cancel_pending')


def gen_greet(rng):
    sc = Scene(rng)
    msg = rng.choice(['hi', 'hello', 'hey', 'hi how are you', "hey, how's your day going?", 'good morning', 'yo', 'hey there',
                      "how's it going", 'hello friend', 'sup', 'good evening'])
    return row(sc, maybe_cap(msg, rng), plan_json('chat', reply=rng.choice(CHAT['greet'][sc.tone])), 'g:greet')


def gen_thanks(rng):
    sc = Scene(rng)
    msg = rng.choice(['thanks', 'thank you', 'thanks, that helps a lot', 'thx', 'you are helpful', 'great, thanks!', 'perfect thank you',
                      'appreciate it', 'ty', 'nice, thanks'])
    return row(sc, maybe_cap(msg, rng), plan_json('chat', reply=rng.choice(CHAT['thanks'][sc.tone])), 'g:thanks')


def gen_feeling(rng):
    sc = Scene(rng)
    msg = rng.choice(["I'm so tired", 'feeling stressed about work', 'I had a great day', "I'm bored", 'ugh, long day',
                      "I'm nervous about my exam", 'I feel happy', 'work was rough', "I'm excited!", 'I am anxious'])
    return row(sc, maybe_cap(msg, rng), plan_json('chat', reply=rng.choice(CHAT['feeling'][sc.tone])), 'g:feeling')


def gen_negated(rng):
    sc = Scene(rng)
    act = fill(rng.choice(ACTIONS)[0], rng)
    msg = rng.choice(["don't remind me to {a}", 'no need to remind me to {a}', "don't add {a}"]).format(a=act)
    intent = 'create_task' if 'add' in msg else 'create_reminder'
    return row(sc, maybe_cap(msg, rng), plan_json(intent, title=act, negated=True, reply=rng.choice(R['negated'][sc.tone])), 'g:negated')


# ------------------------------------------------------------------- main

def check(export_path):
    d = json.load(open(export_path, encoding='utf-8'))
    assert d['planSystem'] == PLAN_SYSTEM, 'PLAN_SYSTEM differs from the app'
    assert d['toneStyles'] == TONE_STYLES, 'TONE_STYLES differs from the app'
    a = render('remind me to call mom at 5pm', datetime(2026, 10, 20, 14, 5),
               '#3 buy milk\n#7 meeting (due tomorrow (Wed 21 Oct) at 3:00 PM)', 'playful', 'Asha', 'teacher',
               ['Last task mentioned: #3 buy milk', 'Earlier user message: hello'],
               'task "dentist" still needs a time', ['User likes tea'])
    assert a == d['sample'], 'render differs from Prompt._renderPlan'
    b = render('hi', datetime(2026, 1, 4, 9, 0), '(none)', 'cheerful')
    assert b == d['sample2'], 'render (empty) differs from Prompt._renderPlan'
    now = datetime(2026, 10, 20, 14, 5)
    assert friendly(datetime(2026, 10, 21, 15, 0), now) == 'tomorrow (Wed 21 Oct) at 3:00 PM'
    print('render check: identical to the app')


def main():
    massive, out_dir = sys.argv[1], sys.argv[2]
    if '--check' in sys.argv:
        check(sys.argv[sys.argv.index('--check') + 1])
    check_banks()
    rng = random.Random(8426)
    rows_m = convert_massive(massive, rng)
    rows_g = generated(rng, 2600)
    rows = rows_m + rows_g
    rng.shuffle(rows)
    n_val = max(50, len(rows) // 20)
    for name, part in (('val', rows[:n_val]), ('train', rows[n_val:])):
        with open(f'{out_dir}/{name}.jsonl', 'w', encoding='utf-8') as f:
            for r in part:
                f.write(json.dumps(r, ensure_ascii=False) + '\n')
    tags = {}
    for r in rows:
        tags[r['tag']] = tags.get(r['tag'], 0) + 1
    print(f'{len(rows)} rows ({len(rows_m)} MASSIVE, {len(rows_g)} generated); val {n_val}')
    print(json.dumps(dict(sorted(tags.items())), indent=0))


if __name__ == '__main__':
    main()
