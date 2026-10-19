#!/usr/bin/env python3
"""Validates the frozen Corenyth evaluation corpus (stdlib only).

  python3 -I eval/validate.py            # validate + verify the freeze manifest
  python3 -I eval/validate.py --summary  # also print counts
  python3 -I eval/validate.py --freeze   # (re)write eval/corpus/FROZEN.json

--freeze is a deliberate, reviewed act: held-out text must never be tuned
against. Changing a frozen file without re-freezing fails validation.
"""
import hashlib
import json
import re
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent
CORPUS = ROOT / 'corpus'
FILES = {'single_dev.jsonl': 'single', 'single_heldout.jsonl': 'single',
         'multi_dev.jsonl': 'multi'}
FROZEN = CORPUS / 'FROZEN.json'
DEFAULTS = {'now': '2026-10-19T07:41', 'timezone': 'Asia/Kolkata'}

CATEGORIES = ['scheduling', 'updates', 'lists', 'progress', 'memory',
              'ambiguity', 'negation', 'chat']
SOURCES = {'user_history', 'plan_matrix', 'gap_report', 'synthetic'}
KINDS = {'write', 'clarify', 'answer', 'reply', 'none'}
CLARIFY_FIELDS = {'time', 'day', 'target', 'conflict', 'title', 'intent',
                  'action', 'confirm_move', 'confirm_complete',
                  'confirm_remove', 'confirm_cancel', 'confirm_reminder',
                  'confirm_duplicate'}
# op -> (required keys, optional keys); refs are checked separately.
OPS = {
    'create_reminder': ({'title_has'}, {'title_not', 'at', 'on', 'lead',
                                        'follow_up', 'scheduled'}),
    'create_task': ({'title_has'}, {'title_not', 'at', 'on'}),
    'create_daily': ({'title_has', 'minute_of_day'}, {'title_not', 'until'}),
    'complete_task': ({'task'}, {'cancels_alerts', 'outcome_has'}),
    'delete_task': ({'task'}, set()),
    'edit_task': ({'task'}, {'at', 'title_has'}),
    'cancel_reminder': ({'reminder'}, set()),
    'save_memory': ({'has'}, {'category'}),
    'supersede_memory': ({'memory', 'has'}, set()),
    'delete_memory': ({'memory'}, set()),
    'set_outcome': ({'task', 'has'}, set()),
    'set_details': ({'task'}, {'ends_at', 'subject_has'}),
}
FORBIDDABLE = set(OPS) | {'any_write'}
EXPECT_KEYS = {'kind', 'changes', 'clarify', 'pending', 'answer', 'about',
               'forbid', 'also_ok', 'reply_has', 'uses_memory',
               'clears_pending', 'clears_awaiting'}
CASE_KEYS = {'id', 'split', 'category', 'source', 'origin', 'input', 'now',
             'setup', 'expect', 'wording', 'tags'}
MULTI_KEYS = {'id', 'split', 'category', 'source', 'origin', 'now', 'setup',
              'turns', 'final_state', 'tags'}
TURN_KEYS = {'input', 'chat', 'advance_min', 'restart_before', 'cancel',
             'expect', 'wording'}
SETUP_KEYS = {'tasks', 'reminders', 'memories', 'history', 'prefs', 'env',
              'pending'}
DT = re.compile(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$')
DATE = re.compile(r'^\d{4}-\d{2}-\d{2}$')
SCREENSHOT = 'Can u remind me i have a meeting within 10 mins'

errors = []


def err(where, msg):
    errors.append(f'{where}: {msg}')


def strs(v):
    return isinstance(v, list) and v and all(isinstance(s, str) and s for s in v)


def check_setup(where, setup):
    refs = {'task': set(), 'reminder': set(), 'memory': set()}
    if setup is None:
        return refs
    if not isinstance(setup, dict):
        err(where, 'setup must be an object')
        return refs
    for k in setup:
        if k not in SETUP_KEYS:
            err(where, f'unknown setup key {k}')
    for key, kind in (('tasks', 'task'), ('reminders', 'reminder'),
                      ('memories', 'memory')):
        for i, row in enumerate(setup.get(key, [])):
            ref = row.get('ref')
            if not isinstance(ref, str) or ref in refs[kind]:
                err(where, f'{key}[{i}] needs a unique ref')
            refs[kind].add(ref)
            if kind == 'memory':
                if not isinstance(row.get('content'), str):
                    err(where, f'{ref} needs content')
                continue
            if not isinstance(row.get('title'), str):
                err(where, f'{ref} needs a title')
            for f in ('due', 'at', 'ends_at'):
                if f in row and not DT.match(row[f]):
                    err(where, f'{ref}.{f} is not YYYY-MM-DDTHH:MM')
    for r in setup.get('reminders', []):
        if 'task' in r and r['task'] not in refs['task']:
            err(where, f"reminder {r.get('ref')} links unknown task {r['task']}")
        if r.get('kind', 'main') not in ('main', 'pre', 'follow_up'):
            err(where, f"reminder {r.get('ref')} has bad kind")
    for h in setup.get('history', []):
        if h.get('role') not in ('user', 'assistant') or not isinstance(
                h.get('content'), str):
            err(where, 'history rows need role and content')
    return refs


def check_ref(where, kind, ref, refs, allow_last):
    if ref == '$last' and allow_last:
        return
    if ref not in refs[kind]:
        err(where, f'unknown {kind} ref {ref!r}')


def check_expect(where, e, refs, allow_last, nested=False):
    if not isinstance(e, dict):
        return err(where, 'expect must be an object')
    for k in e:
        if k not in EXPECT_KEYS:
            err(where, f'unknown expect key {k}')
    kind = e.get('kind')
    if kind not in KINDS:
        return err(where, f'bad kind {kind!r}')
    changes = e.get('changes', [])
    if kind == 'write' and not changes:
        err(where, 'write needs changes')
    if kind != 'write' and changes:
        err(where, f'{kind} must not list changes (state stays unchanged)')
    for i, c in enumerate(changes):
        w = f'{where}.changes[{i}]'
        op = c.get('op')
        if op not in OPS:
            err(w, f'unknown op {op!r}')
            continue
        req, opt = OPS[op]
        keys = set(c) - {'op'}
        for k in req - keys:
            err(w, f'{op} needs {k}')
        for k in keys - req - opt:
            err(w, f'{op} does not take {k}')
        for k in ('title_has', 'title_not', 'has', 'outcome_has',
                  'subject_has'):
            if k in c and not strs(c[k]):
                err(w, f'{k} must be a non-empty string list')
        for k in ('at', 'ends_at'):
            if k in c and not DT.match(str(c[k])):
                err(w, f'{k} is not YYYY-MM-DDTHH:MM')
        for k in ('on', 'until'):
            if k in c and not DATE.match(str(c[k])):
                err(w, f'{k} is not YYYY-MM-DD')
        if 'at' in c and 'on' in c:
            err(w, 'use at or on, not both')
        if op == 'create_reminder' and 'at' not in c and 'on' not in c:
            err(w, 'a reminder needs at or on')
        if op == 'edit_task' and not keys & {'at', 'title_has'}:
            err(w, 'edit_task needs at or title_has')
        if op == 'create_daily' and not (
                isinstance(c['minute_of_day'], int)
                and 0 <= c['minute_of_day'] < 1440):
            err(w, 'minute_of_day must be 0..1439')
        if 'lead' in c and not (isinstance(c['lead'], list) and all(
                isinstance(x, int) and x > 0 for x in c['lead'])):
            err(w, 'lead must be positive minutes')
        for k, kind_ in (('task', 'task'), ('reminder', 'reminder'),
                         ('memory', 'memory')):
            if k in c:
                check_ref(w, kind_, c[k], refs, allow_last)
    if kind == 'clarify':
        cl = e.get('clarify')
        if not isinstance(cl, dict) or cl.get('field') not in CLARIFY_FIELDS:
            err(where, 'clarify needs a known field')
        else:
            for ref in cl.get('candidates', []):
                if ref not in refs['task'] and ref not in refs['reminder']:
                    err(where, f'unknown candidate {ref}')
    elif 'clarify' in e:
        err(where, 'clarify only belongs to kind clarify')
    if kind == 'answer':
        a = e.get('answer')
        if not isinstance(a, dict) or not any(
                a.get(k) for k in ('include', 'exclude', 'include_text',
                                   'exclude_text')):
            err(where, 'answer needs include/exclude facts')
        else:
            for ref in a.get('include', []) + a.get('exclude', []):
                if not any(ref in refs[k] for k in refs):
                    err(where, f'unknown answer ref {ref}')
    elif 'answer' in e:
        err(where, 'answer only belongs to kind answer')
    for ref in e.get('about', []):
        if not any(ref in refs[k] for k in refs):
            err(where, f'unknown about ref {ref}')
    for f in e.get('forbid', []):
        if f not in FORBIDDABLE:
            err(where, f'cannot forbid {f!r}')
    if 'pending' in e and not strs(e['pending'].get('title_has')):
        err(where, 'pending needs title_has')
    if nested and 'also_ok' in e:
        err(where, 'also_ok cannot nest')
    for i, alt in enumerate(e.get('also_ok', [])):
        check_expect(f'{where}.also_ok[{i}]', alt, refs, allow_last, True)


def norm(s):
    return ' '.join(re.findall(r"[a-z0-9%:+*-]+", s.lower()))


def jaccard(a, b):
    x, y = set(norm(a).split()), set(norm(b).split())
    return len(x & y) / max(1, len(x | y))


def canonical(case):
    return json.dumps(case, sort_keys=True, ensure_ascii=False,
                      separators=(',', ':'))


def sha(b):
    return hashlib.sha256(b).hexdigest()


def load():
    out = {}
    for name in FILES:
        path = CORPUS / name
        rows = []
        if not path.exists():
            err(name, 'missing')
            out[name] = rows
            continue
        for n, line in enumerate(path.read_text(encoding='utf-8')
                                 .splitlines(), 1):
            if not line.strip():
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError as e:
                err(f'{name}:{n}', f'invalid JSON ({e})')
        out[name] = rows
    return out


def validate(data):
    ids = set()
    singles, heldout, multis = [], [], []
    for name, rows in data.items():
        for c in rows:
            cid = c.get('id', '?')
            where = f'{name}:{cid}'
            if cid in ids:
                err(where, 'duplicate id')
            ids.add(cid)
            if c.get('category') not in CATEGORIES:
                err(where, f"bad category {c.get('category')!r}")
            if c.get('source') not in SOURCES:
                err(where, f"bad source {c.get('source')!r}")
            if c.get('source') != 'synthetic' and not c.get('origin'):
                err(where, 'non-synthetic cases cite their origin')
            if 'now' in c and not DT.match(c['now']):
                err(where, 'now is not YYYY-MM-DDTHH:MM')
            refs = check_setup(where, c.get('setup'))
            if FILES[name] == 'single':
                for k in c:
                    if k not in CASE_KEYS:
                        err(where, f'unknown key {k}')
                split = 'heldout' if 'heldout' in name else 'dev'
                if c.get('split') != split:
                    err(where, f'split must be {split}')
                if (split == 'heldout') != cid.startswith('H-'):
                    err(where, 'held-out ids start with H-, others never')
                if not isinstance(c.get('input'), str) or not c['input'].strip():
                    err(where, 'needs input')
                    continue
                check_expect(where, c.get('expect'), refs, False)
                (heldout if split == 'heldout' else singles).append(c)
            else:
                for k in c:
                    if k not in MULTI_KEYS:
                        err(where, f'unknown key {k}')
                turns = c.get('turns')
                if not isinstance(turns, list) or len(turns) < 1:
                    err(where, 'needs turns')
                    continue
                if len(turns) < 2 and not c.get('setup'):
                    err(where, 'a one-turn scenario needs setup state')
                for i, t in enumerate(turns):
                    tw = f'{where}.turns[{i}]'
                    for k in t:
                        if k not in TURN_KEYS:
                            err(tw, f'unknown key {k}')
                    if not isinstance(t.get('input'), str):
                        err(tw, 'needs input')
                    if t.get('cancel') not in (None, 'before_commit'):
                        err(tw, 'cancel must be before_commit')
                    if (t.get('expect') or {}).get('kind') == 'none' and \
                            not t.get('cancel'):
                        err(tw, "kind none is only for a cancelled turn")
                    check_expect(tw, t.get('expect'), refs, i > 0)
                multis.append(c)
    all_single = singles + heldout
    # Distinct inputs; held-out must not copy dev text.
    seen = {}
    for c in all_single:
        k = norm(c['input'])
        if k in seen:
            err(c['id'], f'same input as {seen[k]}')
        seen[k] = c['id']
    for h in heldout:
        for d in singles:
            j = jaccard(h['input'], d['input'])
            if j >= 0.7:
                err(h['id'], f'too close to dev {d["id"]} (jaccard {j:.2f})')
    for i, a in enumerate(all_single):
        for b in all_single[i + 1:]:
            if jaccard(a['input'], b['input']) >= 0.85:
                err(a['id'], f'near-duplicate of {b["id"]}')
    # Coverage gates (plan P0).
    if len(all_single) < 120:
        err('corpus', f'{len(all_single)} single-turn cases < 120')
    if len(heldout) < 30:
        err('corpus', f'{len(heldout)} held-out cases < 30')
    if len(multis) < 20:
        err('corpus', f'{len(multis)} multi-turn scenarios < 20')
    by_cat = Counter(c['category'] for c in all_single)
    held_cat = Counter(c['category'] for c in heldout)
    for cat in CATEGORIES:
        if by_cat[cat] < 10:
            err('corpus', f'category {cat} has {by_cat[cat]} < 10 single cases')
        if held_cat[cat] < 3:
            err('corpus', f'category {cat} has {held_cat[cat]} < 3 held-out')
    hist = [c for c in all_single + multis if c['source'] == 'user_history']
    if len(hist) < 15:
        err('corpus', f'only {len(hist)} user_history cases')
    if not any(c.get('input') == SCREENSHOT for c in singles):
        err('corpus', 'the screenshot request is missing from dev')
    return all_single, heldout, multis


def manifest(data):
    files = {n: sha((CORPUS / n).read_bytes()) for n in FILES
             if (CORPUS / n).exists()}
    cases = {c['id']: sha(canonical(c).encode())
             for c in data['single_heldout.jsonl']}
    return {'version': 1, 'defaults': DEFAULTS, 'files': files,
            'heldout_cases': cases}


def main(argv):
    data = load()
    singles, heldout, multis = validate(data)
    if '--freeze' in argv:
        if errors:
            print('\n'.join(errors))
            print(f'NOT FROZEN: {len(errors)} error(s)')
            return 1
        FROZEN.write_text(json.dumps(manifest(data), indent=2,
                                     sort_keys=True) + '\n')
        print(f'froze {FROZEN.relative_to(ROOT.parent)}')
    elif not FROZEN.exists():
        err('FROZEN.json', 'missing: corpus is not frozen')
    else:
        want = json.loads(FROZEN.read_text())
        have = manifest(data)
        for n, h in want['files'].items():
            if have['files'].get(n) != h:
                err('FROZEN.json', f'{n} changed since freeze')
        for cid, h in want['heldout_cases'].items():
            if have['heldout_cases'].get(cid) != h:
                err('FROZEN.json', f'held-out {cid} changed or removed')
        if set(have['heldout_cases']) - set(want['heldout_cases']):
            err('FROZEN.json', 'held-out cases added without re-freeze')
    if '--summary' in argv or not errors:
        print(f'single-turn: {len(singles) - len(heldout)} dev + '
              f'{len(heldout)} held-out = {len(singles)}; '
              f'multi-turn: {len(multis)}')
        cat = Counter(c['category'] for c in singles)
        hc = Counter(c['category'] for c in heldout)
        print('by category (all/held-out): ' + ', '.join(
            f'{k} {cat[k]}/{hc[k]}' for k in CATEGORIES))
        src = Counter(c['source'] for c in singles + multis)
        print('by source: ' + ', '.join(f'{k} {v}' for k, v in sorted(
            src.items())))
        kinds = Counter(c['expect']['kind'] for c in singles)
        print('expected kinds: ' + ', '.join(f'{k} {v}' for k, v in sorted(
            kinds.items())))
    if errors:
        print('\n'.join(errors))
        print(f'INVALID: {len(errors)} error(s)')
        return 1
    print('OK')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
