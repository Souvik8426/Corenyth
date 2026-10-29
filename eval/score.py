#!/usr/bin/env python3
"""Score recorded synthetic SQLite runs. Never substitutes model outputs.

Unimplemented checks are reported as incomplete, never counted as passes.
State checks use an explicit table/id delta; unexpected writes fail.
"""
import collections
import copy
import datetime
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
run = json.loads(path.read_text())
multi = 'scenarios' in run or 'multi' in path.name
split = 'heldout' if 'heldout' in path.name else 'dev'


def load_cases():
    if multi:
        return {c['id']: c for c in map(json.loads, open('eval/corpus/multi_dev.jsonl'))}
    return {c['id']: c for c in map(json.loads, open(f'eval/corpus/single_{split}.jsonl'))}


cases = load_cases()
recorded_ids = [r['id'] for r in (run.get('scenarios') if multi else run['cases'])]
duplicates = sorted(k for k, n in collections.Counter(recorded_ids).items() if n > 1)
missing = sorted(set(cases) - set(recorded_ids))
unexpected = sorted(set(recorded_ids) - set(cases))
if duplicates or missing or unexpected:
    raise SystemExit('Invalid run coverage: ' + json.dumps({
        'duplicates': duplicates, 'missing': missing, 'unexpected': unexpected}))


def epoch(v):
    return int(datetime.datetime.fromisoformat(v).replace(
        tzinfo=datetime.timezone(datetime.timedelta(minutes=330))).timestamp() * 1000)


def day(v):
    return datetime.datetime.fromtimestamp(
        v / 1000, datetime.timezone(datetime.timedelta(minutes=330))).strftime('%Y-%m-%d') if v else ''


IGNORE_FIELDS = {'last_accessed_at', 'updated_at'}


def domain_row(x):
    return {k: v for k, v in x.items() if k not in IGNORE_FIELDS}


def index_rows(rows):
    return {r['id']: domain_row(r) for r in rows}


def delta(before, after, tables=('tasks', 'reminders', 'memories')):
    """Explicit insert/delete/field-change model keyed by table/id."""
    out = {'inserts': {}, 'deletes': {}, 'changes': {}}
    for t in tables:
        b, a = index_rows(before.get(t, [])), index_rows(after.get(t, []))
        out['inserts'][t] = [a[i] for i in a.keys() - b.keys()]
        out['deletes'][t] = [b[i] for i in b.keys() - a.keys()]
        changed = []
        for i in a.keys() & b.keys():
            if a[i] != b[i]:
                changed.append({'id': i, 'before': b[i], 'after': a[i]})
        out['changes'][t] = changed
    return out


def domain_changed(d):
    return any(d['inserts'][t] or d['deletes'][t] or d['changes'][t]
               for t in d['inserts'])


def check(e, r, forbid_ops=None):
    b, a = r['before'], r['after']
    reply = (r.get('reply') or '').lower()
    refs = r.get('refs') or {}
    errors, incomplete = [], []
    d = delta(b, a)
    forbid_ops = set(forbid_ops or []) | set(e.get('forbid') or [])

    def fail(ok, msg):
        if not ok:
            errors.append(msg)

    def row(ref, state=a):
        rr = refs.get(ref, {})
        return next((x for x in state.get(rr.get('table'), []) if x['id'] == rr.get('id')), None)

    def has(row, field, terms):
        return row is not None and all(t.lower() in str(row.get(field, '')).lower() for t in terms)

    def forbidden_present():
        hits = []
        if 'any_write' in forbid_ops and domain_changed(d):
            hits.append('any_write')
        if forbid_ops.intersection({
                'create_reminder', 'create_task', 'create_daily'}) and (
                d['inserts']['reminders'] or d['inserts']['tasks']):
            if 'create_reminder' in forbid_ops and any(
                    x.get('kind', 'reminder') == 'reminder'
                    for x in d['inserts']['reminders']):
                hits.append('create_reminder')
            if 'create_task' in forbid_ops and d['inserts']['tasks']:
                hits.append('create_task')
            if 'create_daily' in forbid_ops and any(
                    x.get('recurrence') == 'daily' for x in d['inserts']['tasks']):
                hits.append('create_daily')
        if 'save_memory' in forbid_ops and any(
                x.get('status', 'active') == 'active'
                for x in d['inserts']['memories']):
            hits.append('save_memory')
        if 'supersede_memory' in forbid_ops and any(
                c['after'].get('status') == 'superseded'
                for c in d['changes']['memories']):
            hits.append('supersede_memory')
        if 'delete_memory' in forbid_ops and d['deletes']['memories']:
            hits.append('delete_memory')
        if 'delete_task' in forbid_ops and d['deletes']['tasks']:
            hits.append('delete_task')
        if 'complete_task' in forbid_ops and any(
                c['after'].get('status') == 'done' and c['before'].get('status') != 'done'
                for c in d['changes']['tasks']):
            hits.append('complete_task')
        if 'cancel_reminder' in forbid_ops and any(
                c['before'].get('enabled') and not c['after'].get('enabled')
                for c in d['changes']['reminders']):
            hits.append('cancel_reminder')
        return hits

    for op in forbidden_present():
        errors.append('forbidden operation present: ' + op)

    if e['kind'] in ['reply', 'answer', 'clarify', 'none']:
        fail(not domain_changed(d), 'unexpected domain write')
    if e['kind'] == 'none':
        fail(not domain_changed(d), 'cancelled turn wrote state')

    if e['kind'] == 'clarify':
        fail('?' in reply, 'missing clarification question')
        field = e.get('clarify', {}).get('field')
        cues = {
            'time': ['when', 'time', 'date', 'which day'],
            'title': ['what', 'about'],
            'target': ['which', 'what', 'who'],
            'conflict': ['which', 'when', 'time', 'conflict', 'disagree'],
            'confirm_complete': ['complete', 'done'],
            'confirm_remove': ['remove', 'delete'],
            'confirm_cancel': ['cancel'],
            'day': ['which day', 'day', 'date', 'when', 'tomorrow', 'today'],
            'action': ['complete', 'cancel', 'remove', 'delete'],
        }
        if field in cues:
            fail(any(s in reply for s in cues[field]), 'wrong clarification field')
        else:
            incomplete.append('clarification semantic field ' + str(field))
        for ref in e.get('clarify', {}).get('candidates', []):
            rr = row(ref)
            fail(rr is not None and ('#' + str(rr['id']) in reply or str(rr.get('title', '')).lower() in reply),
                 'missing candidate ' + ref)

    if 'pending' in e:
        pending = a.get('pending_clarifications') or []
        fail(bool(pending), 'missing persisted pending')
        value = ' '.join(str(json.loads(x['draft']).get('title', '')) for x in pending).lower()
        fail(all(t.lower() in value for t in e['pending'].get('title_has', [])), 'wrong pending title')
        fail(all(t.lower() not in value for t in e['pending'].get('title_not', [])), 'dirty pending title')

    if e.get('clears_pending'):
        fail(not (a.get('pending_clarifications') or []), 'pending not cleared')

    accounted = set()
    if e['kind'] == 'write':
        fail(domain_changed(d), 'missing write')
        for change in e.get('changes', []):
            op = change['op']
            target = None
            if op in ['create_reminder', 'create_task', 'create_daily']:
                table = 'reminders' if op == 'create_reminder' else 'tasks'
                new = d['inserts'][table]
                targets = [x for x in new
                           if has(x, 'title', change.get('title_has', []))
                           and (op != 'create_reminder' or x.get('kind', 'reminder') == 'reminder')]
                fail(len(targets) == 1, 'missing/ambiguous ' + op)
                target = targets[0] if len(targets) == 1 else None
                if target:
                    accounted.add((table, target['id']))
                    fail(all(t.lower() not in target['title'].lower() for t in change.get('title_not', [])),
                         'dirty title')
                    field = 'trigger_at' if table == 'reminders' else 'due_at'
                    if 'at' in change:
                        fail(target[field] == epoch(change['at']), 'wrong timestamp')
                    if 'on' in change:
                        fail(day(target[field]) == change['on'], 'wrong date')
                    if op == 'create_daily':
                        fail(target.get('recurrence') == 'daily', 'missing daily recurrence')
                        fail(target.get('daily_minute') == change['minute_of_day'], 'wrong daily minute')
                        if 'until' in change:
                            fail(day(target.get('deadline_at')) == change['until'], 'wrong daily end date')
                        # The daily task's own trigger row is part of the same write.
                        for x in a['reminders']:
                            if x.get('task_id') == target['id'] and x.get('kind') == 'reminder':
                                accounted.add(('reminders', x['id']))
                    if change.get('lead'):
                        linked = [x for x in a['reminders']
                                  if x.get('task_id') == target.get('task_id')
                                  and x.get('kind') == 'pre' and x.get('enabled')]
                        actual = {(target['trigger_at'] - x['trigger_at']) // 60000 for x in linked}
                        fail(set(change['lead']).issubset(actual), 'requested early alert missing')
                        for x in linked:
                            accounted.add(('reminders', x['id']))
                    if 'follow_up' in change:
                        present = any(x.get('task_id') == target.get('task_id')
                                      and x.get('kind') == 'follow_up'
                                      and x.get('enabled') for x in a['reminders'])
                        fail(present == change['follow_up'], 'wrong follow-up configuration')
                    if 'scheduled' in change:
                        sched = r.get('scheduler') or {}
                        if change['scheduled'] is False:
                            fail(sched.get('issue') is not None or 'notification' in reply,
                                 'expected unschedulable receipt')
                        else:
                            incomplete.append('platform scheduling requires device evidence')
                    # Linked task created with a reminder is subordinate.
                    if table == 'reminders' and target.get('task_id') is not None:
                        accounted.add(('tasks', target['task_id']))
            elif op in ['complete_task', 'edit_task', 'delete_task', 'set_outcome', 'set_details']:
                target = row(change['task'])
                if op == 'delete_task':
                    fail(target is None, 'task not deleted')
                    if change['task'] in refs:
                        accounted.add(('tasks', refs[change['task']]['id']))
                elif op == 'complete_task':
                    fail(target is not None and target['status'] == 'done', 'task not complete')
                    if target:
                        accounted.add(('tasks', target['id']))
                elif op == 'set_outcome':
                    fail(has(target, 'outcome', change.get('has', [])), 'outcome missing')
                    if target:
                        accounted.add(('tasks', target['id']))
                elif op == 'edit_task':
                    fail(target != row(change['task'], b), 'task unchanged')
                    if 'at' in change:
                        fail(target is not None and target['due_at'] == epoch(change['at']), 'wrong moved time')
                    fail(has(target, 'title', change.get('title_has', [])), 'wrong edited title')
                    if target:
                        accounted.add(('tasks', target['id']))
                elif op == 'set_details':
                    if 'ends_at' in change:
                        fail(target is not None and target.get('ends_at') == epoch(change['ends_at']), 'wrong ends_at')
                    if 'subject_has' in change:
                        fail(has(target, 'subject', change.get('subject_has', [])), 'wrong subject')
                    if target:
                        accounted.add(('tasks', target['id']))
                else:
                    incomplete.append('event details')
                    if target:
                        accounted.add(('tasks', target['id']))
                if change.get('outcome_has'):
                    fail(has(target, 'outcome', change['outcome_has']), 'outcome missing')
                if change.get('cancels_alerts'):
                    fail(not any(x['enabled'] and x['task_id'] == refs[change['task']]['id']
                                 for x in a['reminders']), 'alerts still enabled')
            elif op == 'cancel_reminder':
                rr = row(change['reminder'])
                fail(rr is None or not rr['enabled'], 'reminder not cancelled')
                if change['reminder'] in refs:
                    accounted.add(('reminders', refs[change['reminder']]['id']))
            elif op in ['save_memory', 'supersede_memory']:
                hits = [x for x in d['inserts']['memories'] + [c['after'] for c in d['changes']['memories']]
                        if has(x, 'content', change.get('has', [])) and x.get('status', 'active') == 'active']
                fail(bool(hits), 'memory not saved')
                for x in hits:
                    accounted.add(('memories', x['id']))
                if op == 'supersede_memory':
                    old = row(change['memory'])
                    fail(old is not None and old.get('status') == 'superseded', 'old memory not superseded')
                    if old:
                        accounted.add(('memories', old['id']))
            elif op == 'delete_memory':
                fail(row(change['memory']) is None, 'memory not deleted')
                if change['memory'] in refs:
                    accounted.add(('memories', refs[change['memory']]['id']))
            else:
                incomplete.append('op ' + op)

        # Extra unrelated writes fail even when the requested write succeeded.
        for t in ('tasks', 'reminders', 'memories'):
            for x in d['inserts'][t]:
                if (t, x['id']) not in accounted:
                    # Default pre/follow_up alerts linked to an accounted reminder/task are subordinate.
                    if t == 'reminders' and x.get('kind') in ('pre', 'follow_up'):
                        parent = x.get('task_id')
                        if parent is not None and ('tasks', parent) in accounted:
                            continue
                    errors.append(f'unexpected insert {t}:{x["id"]}')
            for ch in d['changes'][t]:
                if (t, ch['id']) not in accounted:
                    # Enabling/disabling subordinate alerts with a completed task is allowed when cancels_alerts.
                    if t == 'reminders':
                        continue  # subordinate alert updates checked via cancels_alerts / lead
                    errors.append(f'unexpected change {t}:{ch["id"]}')
            for x in d['deletes'][t]:
                if (t, x['id']) not in accounted:
                    errors.append(f'unexpected delete {t}:{x["id"]}')

    if 'answer' in e:
        for ref in e['answer'].get('include', []):
            rr = row(ref)
            value = str(rr.get('title', rr.get('content', ''))).lower() if rr else ''
            fail(bool(value) and value in reply, 'missing answer ' + ref)
        for ref in e['answer'].get('exclude', []):
            rr = row(ref)
            value = str(rr.get('title', rr.get('content', ''))).lower() if rr else ''
            fail(not value or value not in reply, 'excluded answer ' + ref)
        for value in e['answer'].get('include_text', []):
            fail(value.lower() in reply, 'missing answer fact')
        for value in e['answer'].get('exclude_text', []):
            fail(value.lower() not in reply, 'excluded answer fact')
    for value in e.get('reply_has', []):
        fail(value.lower() in reply, 'missing reply fact')
    if e.get('about'):
        incomplete.append('groundedness rubric')
    if e.get('uses_memory'):
        incomplete.append('uses_memory evidence')
    return errors, incomplete


def score_expect(expect, recorded):
    """Evaluate expect and every also_ok fully; forbid applies across all alts."""
    options = [expect] + list(expect.get('also_ok') or [])
    forbid = set(expect.get('forbid') or [])
    for alt in expect.get('also_ok') or []:
        forbid |= set(alt.get('forbid') or [])
    scored = []
    for opt in options:
        e = copy.deepcopy(opt)
        e_forbid = set(e.get('forbid') or []) | forbid
        # An incomplete alternative cannot erase a known forbidden operation.
        errors, incomplete = check(e, recorded, forbid_ops=e_forbid)
        scored.append((errors, incomplete))
    # Prefer a clean pass; never let an incomplete alt hide forbid failures.
    def key(s):
        errors, incomplete = s
        forbid_hit = any(x.startswith('forbidden operation') for x in errors)
        return (0 if not errors else 1, 1 if forbid_hit else 0, len(errors), len(incomplete))
    return min(scored, key=key)


def check_final_state(final_expect, snapshot, refs):
    errors = []
    if not final_expect:
        return errors
    pending = snapshot.get('pending_clarifications') or []
    if 'pending' in final_expect:
        if final_expect['pending'] is None:
            if pending:
                errors.append('final pending not cleared')
        elif not pending:
            errors.append('final pending missing')
    for table, key in (('reminders', 'reminders'), ('tasks', 'tasks'), ('memories', 'memories')):
        specs = final_expect.get(key) or []
        if isinstance(specs, dict):
            for term in specs.get('lacks', []):
                if any(term.lower() in str(x.get('content', '')).lower()
                       for x in snapshot.get(table, [])):
                    errors.append(f'final {table} contains forbidden fact {term}')
            unknown = set(specs) - {'lacks'}
            if unknown:
                errors.append(f'unsupported final assertion {sorted(unknown)}')
            continue
        if key in final_expect and specs == [] and snapshot.get(table):
            errors.append(f'final {table} expected empty')
        for spec in specs:
            if 'ref' in spec:
                rr = refs.get(spec['ref'], {})
                row = next((x for x in snapshot.get(table, []) if x['id'] == rr.get('id')), None)
                if 'done' in spec:
                    want = 'done' if spec['done'] else 'pending'
                    if row is None or row.get('status') != want:
                        errors.append(f'final {spec["ref"]} status')
                continue
            terms = [t.lower() for t in spec.get('title_has', [])]
            matches = [x for x in snapshot.get(table, [])
                       if all(t in str(x.get('title', x.get('content', ''))).lower() for t in terms)]
            if 'count_min' in spec and len(matches) < spec['count_min']:
                errors.append(f'final {table} minimum count for {terms}')
            if 'count' in spec and len(matches) != spec['count']:
                errors.append(f'final {table} count for {terms}')
    return errors


out = []
if multi:
    for scenario in run['scenarios']:
        cid = scenario['id']
        case = cases[cid]
        turn_results = []
        scenario_errors = []
        if scenario.get('error'):
            scenario_errors.append('harness: ' + scenario['error'])
        for i, turn in enumerate(scenario.get('turns') or []):
            expect = turn.get('expect') or case['turns'][i]['expect']
            errors, incomplete = score_expect(expect, turn)
            status = 'fail' if errors else 'incomplete' if incomplete else 'pass'
            turn_results.append({
                'index': i, 'status': status, 'errors': errors, 'unscored': incomplete})
            if errors:
                scenario_errors.extend(f'turn{i}: {e}' for e in errors)
        final_errors = check_final_state(
            scenario.get('final_state') or case.get('final_state'),
            scenario.get('final_snapshot') or {},
            scenario.get('refs') or {})
        scenario_errors.extend(final_errors)
        incomplete = [u for t in turn_results for u in t['unscored']]
        status = ('fail' if scenario_errors else
                  'incomplete' if incomplete else 'pass')
        out.append({
            'id': cid,
            'category': scenario.get('category') or case['category'],
            'status': status,
            'errors': scenario_errors,
            'unscored': incomplete,
            'turns': turn_results,
        })
else:
    for r in run['cases']:
        e = cases[r['id']]['expect']
        errors, incomplete = score_expect(e, r)
        if cases[r['id']].get('setup', {}).get('env'):
            # env is now exercised by the harness scheduler/model flags when present.
            if 'scheduler' not in r and cases[r['id']]['setup']['env'].get('notifications'):
                incomplete.append('fixture environment needs dedicated device/harness check')
        out.append({
            'id': r['id'],
            'category': r['category'],
            'status': 'fail' if errors else 'incomplete' if incomplete else 'pass',
            'errors': errors,
            'unscored': incomplete,
        })

counts = collections.Counter(x['status'] for x in out)
report = {
    'mode': run.get('mode'),
    'split': 'multi' if multi else split,
    'counts': dict(counts),
    'categories': {
        k: dict(collections.Counter(x['status'] for x in out if x['category'] == k))
        for k in sorted({x['category'] for x in out})
    },
    'cases': out,
}
path.with_name(path.stem + '-score.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps({k: v for k, v in report.items() if k != 'cases'}, indent=2))
