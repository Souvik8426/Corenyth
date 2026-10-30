#!/usr/bin/env python3
"""Maps GoEmotions (28 labels, Apache-2.0) onto Corenyth's mascot moods.

The mood is the USER's emotion in their message, never the reply tone
(lib/assistant/engine.dart: "Never infer emotion from the configured reply
tone"). Rows whose labels disagree on a mood are dropped, not guessed.

Usage:
  python3 -I goemotions_mood.py --check
  python3 -I goemotions_mood.py SIMPLIFIED_TRAIN.parquet OUT.jsonl
Writes rows {"text", "mood", "intensity", "confidence", "tag"}.
The fixed intensity/confidence values are placeholders until measured.
"""
import json
import sys

# Must match moodContractMoods in lib/mascot/mascot_emotion.dart.
CONTRACT_MOODS = {'calm', 'happy', 'excited', 'supportive', 'concerned', 'curious', 'unknown'}

# GoEmotions simplified label names, in dataset id order (0..27).
GO_LABELS = [
    'admiration', 'amusement', 'anger', 'annoyance', 'approval', 'caring',
    'confusion', 'curiosity', 'desire', 'disappointment', 'disapproval',
    'disgust', 'embarrassment', 'excitement', 'fear', 'gratitude', 'grief',
    'joy', 'love', 'nervousness', 'optimism', 'pride', 'realization',
    'relief', 'remorse', 'sadness', 'surprise', 'neutral',
]

MOOD_OF = {
    'happy': ['admiration', 'amusement', 'gratitude', 'joy', 'love', 'optimism', 'pride', 'relief'],
    'excited': ['excitement'],
    'supportive': ['anger', 'annoyance', 'disappointment', 'disapproval', 'disgust',
                   'embarrassment', 'grief', 'remorse', 'sadness'],
    'concerned': ['fear', 'nervousness'],
    'curious': ['confusion', 'curiosity', 'realization', 'surprise'],
    'calm': ['neutral'],
}
# Ambiguous for a mood: dropped when they are the only labels, ignored when
# another label on the row maps to a mood.
DROPPED = {'approval', 'caring', 'desire'}

# Placeholder numbers; the dataset carries no intensity or confidence.
INTENSITY = {'calm': 0.25, 'excited': 0.8}
DEFAULT_INTENSITY = 0.6
CONFIDENCE = 0.8


def label_mood(name):
    for mood, names in MOOD_OF.items():
        if name in names:
            return mood
    return None


def row_mood(label_names):
    """One mood for a row, or None when it has none or the labels disagree."""
    moods = {label_mood(n) for n in label_names} - {None}
    if len(moods) != 1:
        return None
    return moods.pop()


def to_row(text, label_names, tag):
    mood = row_mood(label_names)
    if mood is None or mood not in CONTRACT_MOODS:
        return None
    return {
        'text': text,
        'mood': mood,
        'intensity': INTENSITY.get(mood, DEFAULT_INTENSITY),
        'confidence': CONFIDENCE,
        'tag': tag,
    }


def check():
    mapped = [n for names in MOOD_OF.values() for n in names]
    assert len(GO_LABELS) == 28, 'GoEmotions has 27 emotions plus neutral'
    assert len(set(GO_LABELS)) == 28, 'label names must be unique'
    unknown = set(MOOD_OF) - CONTRACT_MOODS
    assert not unknown, f'moods not in the app contract: {unknown}'
    seen = [n for n in mapped if mapped.count(n) > 1]
    assert not seen, f'label mapped twice: {seen}'
    missing = set(GO_LABELS) - set(mapped) - DROPPED
    assert not missing, f'unmapped labels: {sorted(missing)}'
    assert row_mood(['joy', 'sadness']) is None, 'conflicting moods must drop'
    assert row_mood(['joy', 'approval']) == 'happy', 'dropped label must not block a mood'
    assert row_mood(['approval']) is None, 'a dropped-only row has no mood'
    assert to_row('hi', ['neutral'], 't')['mood'] == 'calm'
    row = to_row('I passed!', ['pride'], 't')
    assert 0 <= row['intensity'] <= 1 and 0 <= row['confidence'] <= 1
    print('goemotions_mood: self-test OK')


def convert(src, out):
    import pyarrow.parquet as pq  # only needed for the real conversion
    table = pq.read_table(src).to_pylist()
    kept = 0
    with open(out, 'w', encoding='utf-8') as f:
        for i, r in enumerate(table):
            names = [GO_LABELS[k] for k in r['labels']]
            row = to_row(r['text'], names, f'goemotions-{i}')
            if row is None:
                continue
            f.write(json.dumps(row, ensure_ascii=False) + '\n')
            kept += 1
    print(f'kept {kept} of {len(table)} rows -> {out}')


if __name__ == '__main__':
    if sys.argv[1:] == ['--check']:
        check()
    elif len(sys.argv) == 3:
        convert(sys.argv[1], sys.argv[2])
    else:
        sys.exit(__doc__)
