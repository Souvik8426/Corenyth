#!/usr/bin/env python3
"""Content identity for an uncommitted candidate, including new source files."""
import hashlib,json,pathlib,subprocess
root=pathlib.Path(__file__).resolve().parents[1]
files=[]
for directory in ['lib','android/app/src/main','test','eval']:
 for p in (root/directory).rglob('*'):
  if p.is_file() and not any(x in p.parts for x in ['llama.cpp','results','__pycache__']): files.append(p)
files.extend(root/p for p in ['pubspec.yaml','android/app/build.gradle.kts'] if (root/p).exists())
manifest={str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(files)}
identity=hashlib.sha256(json.dumps(manifest,sort_keys=True).encode()).hexdigest()
result={'base_commit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),'source_sha256':identity,'files':manifest}
(root/'eval/results').mkdir(exist_ok=True)
(root/'eval/results/source-manifest.json').write_text(json.dumps(result,indent=2)+'\n')
print(result['base_commit'][:7]+'-dirty-'+identity[:12])
