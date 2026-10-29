import 'package:assistant/mascot/mascot_emotion.dart';

/// One labelled prompt for model-mood evaluation. [accepted] lists every mood
/// an independent labeller accepts for the text; ambiguous cases allow a set,
/// so agreement scoring never forces a single answer.
class MoodCase {
  final String text;
  final List<MascotMood> accepted;
  final String category;
  const MoodCase(this.text, this.accepted, this.category);
}

/// Frozen development corpus (Prompt 1 work package): the shared yardstick
/// for plumbing tests and prompt iterations. NEVER tune application code or
/// prompt wording to individual entries; the model, not a case function,
/// must generalise across them.
const devCorpus = <MoodCase>[
  // Explicit feelings.
  MoodCase('I feel happy today', [MascotMood.happy], 'explicit joy'),
  MoodCase("I'm so excited, I got the job!", [MascotMood.excited], 'explicit joy'),
  MoodCase('I feel sad', [MascotMood.supportive], 'explicit sadness'),
  MoodCase('My father passed away last week', [MascotMood.supportive], 'grief'),
  MoodCase("I'm worried about my results", [MascotMood.concerned], 'explicit concern'),
  MoodCase('I feel frustrated', [MascotMood.supportive, MascotMood.concerned],
      'frustration'),
  MoodCase('I am concerned about tomorrow', [MascotMood.concerned], 'concern'),
  // Implicit joy.
  MoodCase('Yay!', [MascotMood.happy, MascotMood.excited], 'implicit joy'),
  MoodCase('That made my day!', [MascotMood.happy], 'implicit joy'),
  MoodCase('We finally nailed it after weeks of work',
      [MascotMood.excited, MascotMood.happy], 'implicit joy'),
  // Negation and ambiguity.
  MoodCase('I am not feeling happy', [MascotMood.supportive, MascotMood.concerned],
      'negated joy'),
  MoodCase("I'm not worried, just tired",
      [MascotMood.supportive, MascotMood.calm], 'negated concern'),
  MoodCase('Sure, that went GREAT.', [MascotMood.supportive, MascotMood.concerned,
    MascotMood.calm], 'sarcasm/ambiguity'),
  // Fiction, quotation, hypotheticals.
  MoodCase('I am happy because the movie was wonderful',
      [MascotMood.happy], 'feeling about fiction'),
  MoodCase('The movie character is sad', [MascotMood.calm, MascotMood.curious],
      'fictional feelings'),
  MoodCase('Translate "I feel sad" to Spanish',
      [MascotMood.calm, MascotMood.curious], 'quoted text'),
  MoodCase('If I feel sad, what would you do?',
      [MascotMood.calm, MascotMood.curious], 'hypothetical'),
  MoodCase('Write a story where the hero is anxious',
      [MascotMood.calm, MascotMood.curious], 'fiction request'),
  // Mixed emotions.
  MoodCase("I'm happy but I'm scared",
      [MascotMood.concerned, MascotMood.supportive], 'mixed emotion'),
  MoodCase('I got the promotion, but I dread telling my team',
      [MascotMood.concerned, MascotMood.supportive], 'mixed emotion'),
  // Neutral commands and questions.
  MoodCase('Set a timer for five minutes', [MascotMood.calm], 'neutral command'),
  MoodCase('remind me to call mum at 5', [MascotMood.calm], 'neutral command'),
  MoodCase('what tasks do I have today', [MascotMood.calm], 'neutral question'),
  MoodCase('12 * 34', [MascotMood.calm], 'neutral command'),
  // Long message.
  MoodCase(
      'I have been trying to finish this report all week and every time I sit '
      'down to work on it something else comes up, and now the deadline is '
      'tomorrow morning and I honestly do not know how I am going to get it '
      'done in time',
      [MascotMood.supportive, MascotMood.concerned],
      'long message'),
];

/// Held-out paraphrases: written separately from the dev corpus and never
/// used to choose wording. The release gate (Prompt 7) scores the installed
/// model against these on the phone; unknown readings count as misses, not
/// crashes.
const heldOutCorpus = <MoodCase>[
  MoodCase('Honestly this made me grin from ear to ear',
      [MascotMood.happy, MascotMood.excited], 'held-out implicit joy'),
  MoodCase("Can't stop smiling, she said yes!",
      [MascotMood.excited, MascotMood.happy], 'held-out joy'),
  MoodCase('Everything keeps going wrong today and I am exhausted',
      [MascotMood.supportive, MascotMood.concerned], 'held-out distress'),
  MoodCase('I keep thinking about the exam and my stomach hurts',
      [MascotMood.concerned], 'held-out worry'),
  MoodCase('I did not say I was upset', [MascotMood.calm, MascotMood.curious],
      'held-out negation'),
  MoodCase('My dog died yesterday', [MascotMood.supportive], 'held-out grief'),
  MoodCase('In the film the villain feels lonely',
      [MascotMood.calm, MascotMood.curious], 'held-out fiction'),
  MoodCase('How do I say "I am thrilled" in French?',
      [MascotMood.calm, MascotMood.curious], 'held-out quoted text'),
  MoodCase('会议准备的怎么样都还没开始，有点慌',
      [MascotMood.concerned, MascotMood.supportive],
      'held-out code-switched concern'),
  MoodCase('me alegra mucho verte otra vez',
      [MascotMood.happy, MascotMood.excited], 'held-out Spanish joy'),
  MoodCase('add milk to the shopping list', [MascotMood.calm],
      'held-out neutral command'),
  MoodCase('The biopsy results come back on Friday and I cannot stop '
      'thinking about it',
      [MascotMood.concerned, MascotMood.supportive], 'held-out long message'),
];
