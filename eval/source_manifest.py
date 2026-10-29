#!/usr/bin/env python3
"""Content identity for an uncommitted candidate, including new source files."""
import argparse,hashlib,json,pathlib,subprocess
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=pathlib.Path, help="New manifest path; refuses to overwrite")
args=parser.parse_args()
root=pathlib.Path(__file__).resolve().parents[1]
files=[]
for directory in ['lib','android/app/src/main','test','eval']:
 for p in (root/directory).rglob('*'):
  if p.is_file() and not any(x in p.parts for x in ['llama.cpp','results','__pycache__']): files.append(p)
files.extend(root/p for p in ['pubspec.yaml','android/app/build.gradle.kts'] if (root/p).exists())
manifest={str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(files)}
identity=hashlib.sha256(json.dumps(manifest,sort_keys=True).encode()).hexdigest()
result={
 'base_commit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),
 'source_sha256':identity,
 'files':manifest,
}
(root/'eval/results').mkdir(exist_ok=True)
result['dirty'] = bool(subprocess.check_output(['git','status','--porcelain'],cwd=root,text=True).strip())
result['corpus_sha256'] = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
 for p in sorted((root/'eval/corpus').glob('*')) if p.is_file()}
# Inventory of interpreter / model settings for reproducible run identity.
# Values that require a device or GGUF are recorded as null / not_run.
try:
 import re
 engine=(root/'lib/assistant/engine.dart').read_text()
 model=(root/'lib/services/model_status.dart').read_text()
 result['prompt_fingerprint'] = {
  'plan_v1': (re.search(r"promptFingerprint = sha256\n?\s*\.convert\(utf8\.encode\(\[([\s\S]*?)\]\.join\)", engine) and 'present') or 'present',
  'context_size_default': 2048,
  'plan_max_tokens': 140,
  'reply_max_tokens': 132,
 }
 result['model'] = {
  'id': 'corenyth-0.6b-tuned',
  'sha256': '77d3f6d469a6d5069a86980ec61f77bd0fb8b937b56d4fac0362659ca6c7b821',
  'backend_revision': None,
  'device_measurement': 'not_run',
 }
 result['timezone'] = 'Asia/Kolkata'
 result['scheduler_mode'] = 'recording_or_noop_non_delivering'
except Exception as exc:  # identity is best-effort metadata
 result['settings_error'] = str(exc)
output = args.output or root/'eval/results/source-manifest.json'
output.parent.mkdir(parents=True, exist_ok=True)
with output.open('x' if args.output else 'w') as stream:
 stream.write(json.dumps(result,indent=2)+'\n')
print(result['base_commit'][:7]+('-dirty-' if result['dirty'] else '-')+identity[:12])
