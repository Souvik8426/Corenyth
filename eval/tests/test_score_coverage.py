"""Negative controls for incomplete and corrupted evaluation runs."""
import copy
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CORPUS = [json.loads(l) for l in open(ROOT / 'eval/corpus/single_dev.jsonl')]


def _base_run():
    return json.loads((ROOT / 'eval/results/rules-dev.json').read_text())


def _case(run, case_id):
    return next(c for c in run['cases'] if c['id'] == case_id)


class CoverageTests(unittest.TestCase):
    def setUp(self):
        self.run = _base_run()

    def score(self, run):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'rules-dev.json'
            path.write_text(json.dumps(run))
            return subprocess.run(
                ['python3', '-I', 'eval/score.py', str(path)],
                cwd=ROOT, capture_output=True, text=True)

    def test_complete_recording_is_accepted(self):
        self.assertEqual(self.score(self.run).returncode, 0)

    def test_missing_duplicate_and_unknown_cases_are_rejected(self):
        for kind in ['missing', 'duplicate', 'unexpected']:
            with self.subTest(kind=kind):
                run = copy.deepcopy(self.run)
                if kind == 'missing':
                    run['cases'].pop()
                elif kind == 'duplicate':
                    run['cases'].append(copy.deepcopy(run['cases'][0]))
                else:
                    run['cases'][0]['id'] = 'UNKNOWN'
                result = self.score(run)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(kind, result.stderr)


class StateDeltaNegativeControls(unittest.TestCase):
    """Each corruption must fail for the intended reason."""

    def setUp(self):
        self.run = _base_run()

    def _score_mutated(self, run, case_id):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'rules-dev.json'
            path.write_text(json.dumps(run))
            proc = subprocess.run(
                ['python3', '-I', 'eval/score.py', str(path)],
                cwd=ROOT, capture_output=True, text=True)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            report = json.loads(path.with_name('rules-dev-score.json').read_text())
            return next(c for c in report['cases'] if c['id'] == case_id)

    def test_extra_task_write_fails(self):
        run = copy.deepcopy(self.run)
        case = _case(run, 'S-001')
        case['after']['tasks'] = list(case['after']['tasks']) + [{
            'id': 9999, 'title': 'smuggled task', 'status': 'pending',
            'created_at': 0, 'due_at': None}]
        scored = self._score_mutated(run, 'S-001')
        self.assertEqual(scored['status'], 'fail')
        self.assertTrue(any('unexpected' in e for e in scored['errors']), scored['errors'])

    def test_wrong_timestamp_fails(self):
        run = copy.deepcopy(self.run)
        case = _case(run, 'S-001')
        reminders = case['after'].get('reminders') or []
        if not reminders:
            self.skipTest('S-001 has no reminder row in this baseline')
        reminders[0] = dict(reminders[0])
        reminders[0]['trigger_at'] = int(reminders[0]['trigger_at']) + 60000
        case['after']['reminders'] = reminders
        scored = self._score_mutated(run, 'S-001')
        self.assertEqual(scored['status'], 'fail')
        self.assertTrue(
            any('timestamp' in e or 'date' in e or 'ambiguous' in e for e in scored['errors']),
            scored['errors'])

    def test_missing_deletion_fails(self):
        target = next(
            (c for c in CORPUS
             if c['expect']['kind'] == 'write'
             and any(ch['op'] == 'delete_task' for ch in c['expect'].get('changes', []))),
            None)
        if target is None:
            self.skipTest('no delete_task case in development corpus')
        run = copy.deepcopy(self.run)
        case = _case(run, target['id'])
        ref = next(ch['task'] for ch in target['expect']['changes'] if ch['op'] == 'delete_task')
        rid = case['refs'][ref]['id']
        before_row = next(t for t in case['before']['tasks'] if t['id'] == rid)
        case['after']['tasks'] = list(case['after']['tasks']) + [before_row]
        scored = self._score_mutated(run, target['id'])
        self.assertEqual(scored['status'], 'fail')
        self.assertTrue(any('deleted' in e for e in scored['errors']), scored['errors'])

    def test_active_superseded_fact_fails(self):
        target = next(
            (c for c in CORPUS
             if any(ch['op'] == 'supersede_memory' for ch in c['expect'].get('changes', []))),
            None)
        if target is None:
            self.skipTest('no supersede_memory case')
        run = copy.deepcopy(self.run)
        case = _case(run, target['id'])
        mem_ref = next(ch['memory'] for ch in target['expect']['changes']
                       if ch['op'] == 'supersede_memory')
        mid = case['refs'][mem_ref]['id']
        after = []
        for m in case['after']['memories']:
            row = dict(m)
            if row['id'] == mid:
                row['status'] = 'active'
            after.append(row)
        case['after']['memories'] = after
        scored = self._score_mutated(run, target['id'])
        self.assertEqual(scored['status'], 'fail')
        self.assertTrue(any('superseded' in e for e in scored['errors']), scored['errors'])

    def test_forbid_is_hard_fail(self):
        target = next((c for c in CORPUS if c['expect'].get('forbid')), None)
        if target is None:
            self.skipTest('no forbid case')
        run = copy.deepcopy(self.run)
        case = _case(run, target['id'])
        case['after']['memories'] = list(case['after'].get('memories') or []) + [{
            'id': 4242, 'content': 'smuggled fact', 'status': 'active',
            'category': 'fact', 'created_at': 0, 'updated_at': 0, 'importance': 0.5}]
        scored = self._score_mutated(run, target['id'])
        self.assertEqual(scored['status'], 'fail')
        self.assertTrue(
            any('forbidden' in e or 'unexpected' in e for e in scored['errors']),
            scored['errors'])

    def test_about_rubric_is_incomplete_not_pass(self):
        target = next((c for c in CORPUS if c['expect'].get('about')), None)
        if target is None:
            self.skipTest('no about case')
        run = copy.deepcopy(self.run)
        scored = self._score_mutated(run, target['id'])
        self.assertIn(scored['status'], ('incomplete', 'fail'))
        if scored['status'] == 'incomplete':
            self.assertTrue(any('groundedness' in u for u in scored['unscored']))


class ManifestTests(unittest.TestCase):
    def test_explicit_output_refuses_overwrite(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'source-manifest.json'
            first = subprocess.run(
                ['python3', '-I', 'eval/source_manifest.py', '--output', str(path)],
                cwd=ROOT, capture_output=True, text=True)
            self.assertEqual(first.returncode, 0, first.stderr)
            second = subprocess.run(
                ['python3', '-I', 'eval/source_manifest.py', '--output', str(path)],
                cwd=ROOT, capture_output=True, text=True)
            self.assertNotEqual(second.returncode, 0)
            data = json.loads(path.read_text())
            self.assertIn('dirty', data)
            self.assertIn('corpus_sha256', data)


if __name__ == '__main__':
    unittest.main()
