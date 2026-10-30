#!/usr/bin/env python3
"""Builds the personality and mood rows that sit next to build_dataset.py's plan rows.

1. Reply rows from the personality export (multi-turn chats, one row per assistant
   turn): the reply contract, `{"emotion":{...},"type":"respond","text":"..."}`.
2. Plan rows for emotional messages (GoEmotions mapped to mascot moods plus generated
   excited/concerned messages): the plan contract with intent chat, create_task or
   create_reminder. A row is kept only when GoEmotions' mood (or the intended mood) and
   an independent rubric reading agree.

Usage:
  python3 -I build_chat_rows.py EXPORT_DIR TURN_LABELS.jsonl POOL.jsonl PLAN_LABELS.jsonl OUT_DIR
Writes OUT_DIR/reply_train.jsonl, reply_val.jsonl, mood_train.jsonl, mood_val.jsonl and a report.
Rows are {"prompt", "completion", "tag"}.
"""
import collections
import json
import os
import random
import re
import sys
from datetime import datetime, timedelta

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # -I drops the script folder
import build_dataset as bd  # noqa: E402

PER_MOOD = 1000
VAL_PER_MOOD = 50

# The Facts block the app sends with a reply prompt: small talk (session.dart `_converse`), and the
# separate mood-reading job, which has no history and whose reply text is unused.
GOAL_TALK = 'Goal: Small talk or a general message. Reply naturally to what the user actually said, in one or two sentences.'
GOAL_RESPOND = 'Goal: Respond to the actual message. No tasks, reminders or actions were requested.'
GOAL_MOOD = "Goal: a mascot mood reading of the user's current message. The reply text is not shown or used."


def load(path):
    return [json.loads(l) for l in open(path, encoding='utf-8') if l.strip()]


def random_now(rng):
    return datetime(2026, 1, 1, 7, 0) + timedelta(days=rng.randrange(330), minutes=rng.randrange(16 * 60))


def profile(rng, voice):
    """A profile tone that maps to the voice, with a name or job sometimes."""
    tone = rng.choice(bd.tone_choices(voice))
    name, occ = rng.choice(bd.PROFILES) if rng.random() < 0.3 else ('', '')
    return tone, bd.personal_context(name, occ, tone)


def reply_rows(export_dir, labels, seed=20261030):
    """One reply-contract row per assistant turn, with the earlier turns as history."""
    out = {'train': [], 'val': []}
    skipped = 0
    for split, fname in (('train', 'train.jsonl'), ('val', 'validation.jsonl')):
        for ci, line in enumerate(open(os.path.join(export_dir, fname), encoding='utf-8')):
            msgs = json.loads(line)['messages']
            voice = re.search(r'Selected personality: (\w+)\.', msgs[0]['content']).group(1)
            assert msgs[0]['content'] == bd.PERSONALITIES[voice], 'system message differs from the app personality'
            rng = random.Random(f'{seed}:{split}:{ci}')
            now = random_now(rng)
            tone, personal = profile(rng, voice)
            history, turn = [], 0
            for k, m in enumerate(msgs[1:], start=1):
                if m['role'] == 'user':
                    pending_user = m['content']
                    continue
                label = labels.get(f'{split}:{ci}:{turn}')
                turn += 1
                if label is None:
                    skipped += 1
                    history += [('user', pending_user), ('assistant', m['content'])]
                    continue
                roll = rng.random()
                goal, hist = (GOAL_TALK, history) if roll < 0.65 else (GOAL_RESPOND, history) if roll < 0.80 else (GOAL_MOOD, [])
                prompt = bd.render_reply(hist, pending_user, now, tone, personal, goal)
                completion = bd.reply_json(label['mood'], label['intensity'], m['content']) + '<|im_end|>'
                out[split].append({'prompt': prompt, 'completion': completion, 'tag': f'p:{voice}:{label["mood"]}'})
                history += [('user', pending_user), ('assistant', m['content'])]
    return out, skipped


def valid_plan(x, text):
    """The agy plan reading as a plan row's fields, or None when it breaks a rule."""
    intent = x['intent']
    if intent not in ('chat', 'create_task', 'create_reminder'):
        return None
    reply = x['reply'].strip()
    check = bd.safe_chat if intent == 'chat' else bd.safe_follow_up
    if not reply or not bd.reply_ok(reply) or not check(reply):
        return None
    f = {'reply': reply}
    if intent != 'chat':
        title, when = x.get('title', '').strip(), x.get('when', '').strip()
        if not title or len(title.split()) > 8 or '{' in title:
            return None
        if when and when.lower() not in text.lower():
            return None
        f['title'] = title
        if when:
            f['when'] = when
    return intent, f


def mood_rows(pool, plan, seed=20261031):
    """Plan-contract rows for emotional messages, agreement filtered and capped per mood."""
    by_id = {p['id']: p for p in pool}
    cand = collections.defaultdict(list)
    seen = collections.Counter()
    for x in plan:
        p = by_id.get(x['id'])
        if p is None:
            continue
        seen[p['gold']] += 1
        if x['mood'] != p['gold']:
            continue
        v = valid_plan(x, p['text'])
        if v is None:
            continue
        cand[p['gold']].append((p, x, v))
    rng = random.Random(seed)
    train, val, report = [], [], {}
    for mood in sorted(cand):
        rows = sorted(cand[mood], key=lambda t: t[0]['id'])
        rng.shuffle(rows)
        report[mood] = {'read': seen[mood], 'agreed_and_valid': len(rows)}
        n_val = min(VAL_PER_MOOD, len(rows) // 10)
        rows = rows[:PER_MOOD + n_val]
        for i, (p, x, (intent, f)) in enumerate(rows):
            r = random.Random(f'{seed}:{p["id"]}')
            sc = bd.Scene(r, voice=p['persona'])
            completion = bd.plan_json(intent, mood=(mood, max(0.1, x['intensity'])), **f) + '<|im_end|>'
            row = {'prompt': sc.prompt(p['text']), 'completion': completion, 'tag': f'e:{mood}:{p["source"]}'}
            (val if i < n_val else train).append(row)
        report[mood]['train'] = sum(1 for r in train if r['tag'].startswith(f'e:{mood}:'))
        report[mood]['val'] = sum(1 for r in val if r['tag'].startswith(f'e:{mood}:'))
    return train, val, report


def write(path, rows):
    with open(path, 'w', encoding='utf-8') as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + '\n')


def main():
    export_dir, turn_labels, pool_path, plan_labels, out_dir = sys.argv[1:6]
    bd.init_banks()
    labels = {x['id']: x for x in load(turn_labels)}
    rep, skipped = reply_rows(export_dir, labels)
    mt, mv, report = mood_rows(load(pool_path), load(plan_labels))
    for name, rows in (('reply_train', rep['train']), ('reply_val', rep['val']), ('mood_train', mt), ('mood_val', mv)):
        write(os.path.join(out_dir, name + '.jsonl'), rows)
    moods = collections.Counter(r['tag'].split(':')[2] for r in rep['train'])
    print(f'reply rows: train {len(rep["train"])}, val {len(rep["val"])}, turns without a label {skipped}')
    print('reply mood mix:', dict(moods))
    print('mood rows:', json.dumps(report))
    print(f'mood rows: train {len(mt)}, val {len(mv)}')


if __name__ == '__main__':
    main()
