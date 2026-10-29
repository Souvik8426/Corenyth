"""Generate extra training rows with a teacher model served by Ollama.

Two steps per example, both through Ollama's local HTTP API:

1. The teacher writes varied user messages for one intent (casual, typos,
   Hinglish, long and short).
2. The teacher labels each message with the app's own PLAN_SYSTEM, and the row
   is kept only when the label is valid JSON, names the requested intent, and
   passes the same reply filters the app applies.

Prompts are rendered by build_dataset.render, so they match the app exactly.
Any message whose normalised text appears in eval/corpus (dev or held-out) is
dropped, so the evaluation stays honest.

Usage:
  python3 -I training/generate_teacher.py OUT_DIR [--per-intent 150] [--model minimax-m3.1-flash:cloud] [--seed 8426]

Writes OUT_DIR/teacher.jsonl (training rows, same shape as build_dataset.py)
and OUT_DIR/teacher_review.jsonl (message, label and tone, for reading).
"""
import argparse
import concurrent.futures as cf
import glob
import json
import os
import random
import re
import subprocess
import sys
import urllib.request
from datetime import datetime, timedelta

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_dataset as bd  # noqa: E402

OLLAMA = 'http://localhost:11434/api/chat'
ALLOWED = {'create_task', 'create_reminder', 'complete', 'delete', 'postpone', 'list',
           'recall', 'answer_pending', 'cancel_pending', 'chat'}

# How many messages to aim for per intent (scaled by --per-intent).
WEIGHTS = {'create_task': 1.0, 'create_reminder': 1.0, 'complete': 0.7, 'delete': 0.5,
           'postpone': 0.5, 'list': 0.6, 'recall': 0.4, 'answer_pending': 0.4,
           'cancel_pending': 0.3, 'chat': 0.9}

DESC = {
    'create_task': 'something the user needs to do, with or without a time (e.g. "buy eggs", "dentist on friday")',
    'create_reminder': 'a request to be reminded or notified of something at a time (e.g. "remind me to call mom at 5")',
    'complete': 'the user saying something is already done (e.g. "I paid the bill")',
    'delete': 'the user asking to remove or cancel a task that exists',
    'postpone': 'the user asking to move a task to later (e.g. "push the gym to tomorrow")',
    'list': 'the user asking what is planned, pending or due',
    'recall': 'the user asking what they told the assistant earlier (e.g. "what did I say about the trip")',
    'answer_pending': 'a short answer that gives a time the assistant asked for (e.g. "7pm")',
    'cancel_pending': 'the user dropping a question the assistant asked (e.g. "never mind")',
    'chat': 'small talk, a feeling, thanks, a greeting, or a general question',
}

CLAIM_START = re.compile(
    r"^(done|all set|got it|noted|sure|ok|okay|i'?ll|i will|i'?ve|i have|set|added|saved|marked|scheduled|"
    r"reminder set|task added)\b", re.IGNORECASE)
EMOJI = re.compile('[\U0001F300-\U0001FAFF☀-➿]')
NO_EMOJI = {'mature', 'professional'}

NEGATED = {'create_task': 'the user saying NOT to add something (e.g. "don\'t add the gym")',
           'create_reminder': 'the user saying NOT to be reminded (e.g. "no need to remind me about the call")'}


def ask(messages, model, temperature=0.9):
    if model.startswith('agy:'):
        return ask_agy(messages, model[len('agy:'):])
    body = json.dumps({'model': model, 'stream': False, 'messages': messages,
                       'options': {'temperature': temperature}}).encode()
    req = urllib.request.Request(OLLAMA, data=body, headers={'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=240) as r:
            return json.load(r)['message']['content']
    except Exception as e:  # network or model error: the batch is skipped
        print('ask failed:', e, file=sys.stderr)
        return None


def ask_agy(messages, model):
    """One request through the agy CLI (print mode). Model names carry their effort, e.g. gemini-3.8-flash-low."""
    prompt = '\n\n'.join(m['content'] for m in messages)
    try:
        out = subprocess.run(['agy', f'--print={prompt}', '--model', model, '--output-format', 'json'],
                             capture_output=True, text=True, timeout=300)
        reply = json.loads(out.stdout)
    except Exception as e:
        print('ask failed:', e, file=sys.stderr)
        return None
    if reply.get('status') != 'SUCCESS':
        print('ask failed:', reply.get('error', 'no success'), file=sys.stderr)
        return None
    return reply.get('response')


def first_json(text, opener, closer):
    if not text:
        return None
    start, end = text.find(opener), text.rfind(closer)
    if start < 0 or end <= start:
        return None
    try:
        return json.loads(text[start:end + 1])
    except json.JSONDecodeError:
        return None


def norm(s):
    return re.sub(r'[^a-z0-9 ]+', '', re.sub(r'\s+', ' ', s.lower())).strip()


def eval_inputs():
    seen = set()
    here = os.path.dirname(os.path.abspath(__file__))
    for path in glob.glob(os.path.join(here, '..', 'eval', 'corpus', '*.jsonl')):
        with open(path, encoding='utf-8') as f:
            for line in f:
                if line.strip():
                    seen.add(norm(json.loads(line).get('input', '')))
    seen.discard('')
    return seen


def messages_for(intent, negated, n, model, rng):
    kind = NEGATED[intent] if negated else DESC[intent]
    prompt = (f'Write {n} different messages a person might send to a personal to-do and reminder app.\n'
              f'Kind: {kind}.\n'
              'Vary them: short and long, casual, some with typos or no punctuation, a few in Hinglish '
              '(Hindi written in English letters), some with times like "5pm", "tmrw", "in 20 min". '
              'No two alike. Do not number them.\n'
              f'Return only a JSON array of {n} strings.')
    text = ask([{'role': 'user', 'content': prompt}], model, temperature=1.0)
    items = first_json(text, '[', ']')
    if not isinstance(items, list):
        return []
    return [s.strip() for s in items if isinstance(s, str) and 2 <= len(s.strip()) <= 200]


def label(message, tone, now, intent, negated, model):
    tasks_text = '(none)'
    prompt_user = bd.render(message, now, tasks_text, tone)
    user = prompt_user.split('<|im_start|>user\n', 1)[1].split('<|im_end|>', 1)[0]
    text = ask([{'role': 'system', 'content': bd.PLAN_SYSTEM}, {'role': 'user', 'content': user}],
               model, temperature=0.2)
    plan = first_json(text, '{', '}')
    if not isinstance(plan, dict) or plan.get('intent') != intent:
        return None
    if set(plan) - {'intent', 'title', 'ref', 'when', 'range', 'multiple', 'follow_up', 'negated', 'reply'}:
        return None
    if negated and plan.get('negated') is not True:
        return None
    reply = plan.get('reply')
    if not isinstance(reply, str) or len(reply.split()) > 12:
        return None
    ok = bd.safe_chat(reply) if intent == 'chat' else bd.safe_follow_up(reply)
    if not ok:
        return None
    # The app confirms actions itself, so a reply must not claim one. Mature
    # and professional tones never use emoji.
    if CLAIM_START.search(reply):
        return None
    if tone in NO_EMOJI and EMOJI.search(reply):
        return None
    canonical = json.dumps(plan, ensure_ascii=False, separators=(',', ':'))
    return bd.render(message, now, tasks_text, tone), canonical, prompt_user


def run_intent(intent, negated, count, model, rng, banned, max_attempts=12):
    rows, review, seen = [], [], set()
    attempts = 0
    while len(rows) < count and attempts < max_attempts:
        attempts += 1
        batch = messages_for(intent, negated, 12, model, rng)
        for msg in batch:
            key = norm(msg)
            if not key or key in banned or key in seen:
                continue
            seen.add(key)
            tone = rng.choice(list(bd.TONE_STYLES))
            now = datetime(2026, 10, 1) + timedelta(minutes=rng.randrange(60 * 24 * 60))
            got = label(msg, tone, now, intent, negated, model)
            if got is None:
                continue
            prompt, completion, _ = got
            tag = ('t:negated_' if negated else 't:') + intent
            rows.append({'prompt': prompt, 'completion': completion + '<|im_end|>', 'tag': tag})
            review.append({'message': msg, 'intent': intent, 'negated': negated,
                           'tone': tone, 'label': completion})
            if len(rows) >= count:
                break
    return rows, review


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('out_dir')
    ap.add_argument('--per-intent', type=int, default=150)
    ap.add_argument('--model', default='minimax-m3.1-flash:cloud')
    ap.add_argument('--seed', type=int, default=8426)
    ap.add_argument('--workers', type=int, default=4)
    ap.add_argument('--need', default='', help='top-up: intent=count pairs, e.g. chat=73,cancel_pending=23')
    ap.add_argument('--exclude', default='', help='a previous teacher_review.jsonl; its messages are skipped')
    ap.add_argument('--max-attempts', type=int, default=12)
    args = ap.parse_args()

    bd.check_banks()
    banned = eval_inputs()
    if args.exclude:
        with open(args.exclude, encoding='utf-8') as f:
            banned |= {norm(json.loads(line)['message']) for line in f if line.strip()}
    print(f'excluding {len(banned)} messages', file=sys.stderr)

    jobs = []
    if args.need:
        for pair in args.need.split(','):
            intent, count = pair.split('=')
            jobs.append((intent, False, int(count)))
    else:
        for intent, weight in WEIGHTS.items():
            jobs.append((intent, False, max(5, round(args.per_intent * weight))))
            if intent in NEGATED:
                jobs.append((intent, True, max(5, round(args.per_intent * 0.3))))

    os.makedirs(args.out_dir, exist_ok=True)
    rows_path = os.path.join(args.out_dir, 'teacher.jsonl')
    review_path = os.path.join(args.out_dir, 'teacher_review.jsonl')
    rows = 0
    # Each finished job is appended to disk straight away, so a stopped run keeps its work.
    with cf.ThreadPoolExecutor(max_workers=args.workers) as pool, \
            open(rows_path, 'a', encoding='utf-8') as fr, open(review_path, 'a', encoding='utf-8') as fv:
        futures = {}
        for i, (intent, negated, count) in enumerate(jobs):
            rng = random.Random(args.seed + i)
            futures[pool.submit(run_intent, intent, negated, count, args.model, rng, banned, args.max_attempts)] = (intent, negated, count)
        for fut in cf.as_completed(futures):
            intent, negated, count = futures[fut]
            r, v = fut.result()
            for x in r:
                fr.write(json.dumps(x, ensure_ascii=False) + '\n')
            for x in v:
                fv.write(json.dumps(x, ensure_ascii=False) + '\n')
            fr.flush()
            fv.flush()
            rows += len(r)
            print(f'{intent}{" (negated)" if negated else ""}: {len(r)}/{count}', file=sys.stderr)
    print(f'{rows} rows appended to {rows_path}', file=sys.stderr)


if __name__ == '__main__':
    main()
