#!/usr/bin/env python3
"""One serial implementation stage per launch; parent acceptance is a separate command."""
import argparse
import fcntl
import json
import os
import subprocess
import uuid
from datetime import datetime, timezone
from pathlib import Path

control = Path(__file__).resolve().parent
repo = control.parents[2]
parser = argparse.ArgumentParser()
parser.add_argument('stage', choices=[f'P{i}' for i in range(6)])
parser.add_argument('--accept-review', type=Path)
parser.add_argument('--retry', action='store_true')
parser.add_argument('--resume-session')
parser.add_argument('--resume-agy')
parser.add_argument('--worker', choices=['agy', 'claude'], default='agy')
args = parser.parse_args()
if args.resume_session:
    if args.worker != 'claude':
        raise SystemExit('Claude session resume requires --worker claude')
    uuid.UUID(args.resume_session)
    if not args.retry:
        raise SystemExit('--resume-session requires --retry')
if args.resume_agy:
    uuid.UUID(args.resume_agy)
    if args.worker != 'agy' or not args.retry:
        raise SystemExit('--resume-agy requires --worker agy --retry')
lock = (control / '.workflow.lock').open('a')
try:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    raise SystemExit('Another workflow command is running')
state_path = control / 'state.json'
state = json.loads(state_path.read_text())
entry = state['stages'][args.stage]

def save():
    temporary = state_path.with_suffix('.tmp')
    temporary.write_text(json.dumps(state, indent=2) + '\n')
    os.replace(temporary, state_path)

if args.accept_review:
    if entry['status'] != 'awaiting_review':
        raise SystemExit('Stage is not awaiting review')
    review_path = args.accept_review.resolve()
    review = json.loads(review_path.read_text())
    done_path = Path(entry.get('attempt_dir', state['run_dir'])) / f'{args.stage}-DONE.json'
    done = json.loads(done_path.read_text())
    required = ('stage', 'decision', 'required_software_checks_passed', 'evidence', 'deferred_device_checks')
    if not all(key in review for key in required):
        raise SystemExit('Incomplete parent review contract')
    if review['stage'] != args.stage or done.get('stage') != args.stage:
        raise SystemExit('Stage identity mismatch')
    if entry.get('exit_code') != 0 or review['decision'] != 'accept' or review['required_software_checks_passed'] is not True:
        raise SystemExit('Stage software gate did not pass')
    if done.get('status') not in ('completed', 'partial'):
        raise SystemExit('Worker is blocked or has no completion evidence')
    if not review['evidence'] or not all((repo / p).is_file() for p in review['evidence']):
        raise SystemExit('Missing review evidence files')
    if args.stage == 'P5' and (review['deferred_device_checks'] or review.get('product_device_gate_passed') is not True):
        raise SystemExit('P5 cannot pass with missing physical-device evidence')
    entry.update(status='accepted', review=str(review_path), accepted_at=datetime.now(timezone.utc).isoformat())
    save()
    print(f'{args.stage} accepted from explicit parent evidence')
    raise SystemExit(0)

for dependency in entry['depends_on']:
    if state['stages'][dependency]['status'] != 'accepted':
        raise SystemExit(f'{dependency} is not accepted; refusing {args.stage}')
if entry['status'] == 'accepted':
    raise SystemExit('Already accepted')
if entry['status'] != 'pending' and not args.retry:
    raise SystemExit('Existing attempt requires explicit --retry after parent review/recovery')
if any(value['status'] == 'running' for key, value in state['stages'].items() if key != args.stage):
    raise SystemExit('Another stage is marked running')
run = Path(state['run_dir']).resolve()
attempt = run / f'{args.stage}-{uuid.uuid4().hex[:8]}'
attempt.mkdir(parents=True, exist_ok=False)
entry.setdefault('attempts', []).append(str(attempt))
entry.update(status='running', attempt_dir=str(attempt))
save()
prompt = (control / f'{args.stage}-prompt.md').read_text().replace(state['run_dir'], str(attempt))
(attempt / 'prompt.md').write_text(prompt)
if args.worker == 'agy':
    command = [
        'agy', '--mode', 'accept-edits', '--model', 'gemini-3.8-flash-high',
        '--effort', 'high', '--add-dir', str(repo), '--add-dir', str(attempt),
        '--output-format', 'json', '-p', prompt,
    ]
else:
    command = [
        'claude', '-p', '--permission-mode', 'acceptEdits',
        '--allowedTools', 'Read,Edit,Write,Glob,Grep,Bash',
        '--output-format', 'json', prompt,
    ]
entry.update(worker=args.worker, model='gemini-3.8-flash-high' if args.worker == 'agy' else 'configured-default', effort='high' if args.worker == 'agy' else 'configured-default')
save()
if args.resume_agy:
    command[-2:-2] = ['--conversation', args.resume_agy]
    entry['resumed_agy_conversation'] = args.resume_agy
    save()
if args.resume_session:
    command[-1:-1] = ['--resume', args.resume_session]
    entry['resumed_claude_session'] = args.resume_session
    save()
log = attempt / f'{args.worker}.json'
try:
    with log.open('x') as output:
        runtime_env = dict(os.environ)
        runtime_env['PATH'] = '/Users/kawaiii_neko/development/flutter/bin:/Users/kawaiii_neko/Library/Android/sdk/platform-tools:' + runtime_env.get('PATH', '')
        result = subprocess.run(command, cwd=repo, env=runtime_env, stdout=output, stderr=subprocess.STDOUT)
    entry.update(status='awaiting_review', exit_code=result.returncode, output=str(log))
except BaseException as error:
    entry.update(status='interrupted', error=type(error).__name__, output=str(log))
    save()
    raise
save()
print(json.dumps({'stage': args.stage, 'exit_code': result.returncode, 'output': str(log), 'done_exists': (attempt / f'{args.stage}-DONE.json').exists()}))
raise SystemExit(result.returncode)
