#!/usr/bin/env python3
"""Packs what the Colab notebook needs into corenyth_training_bundle.zip.

Usage: python3 -I make_bundle.py ROWS_DIR OUT.zip
ROWS_DIR holds reply_train/reply_val/mood_train/mood_val.jsonl from build_chat_rows.py.
The zip holds build_dataset.py, app_prompts.py, reply_banks.json and bundle/*.jsonl.
"""
import os
import sys
import zipfile

here = os.path.dirname(os.path.abspath(__file__))
rows_dir, out = sys.argv[1], sys.argv[2]
files = [(os.path.join(here, n), n) for n in ('build_dataset.py', 'app_prompts.py', 'reply_banks.json')]
files += [(os.path.join(rows_dir, n + '.jsonl'), 'bundle/' + n + '.jsonl')
          for n in ('reply_train', 'reply_val', 'mood_train', 'mood_val')]
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for src, name in files:
        z.write(src, name)
        print(f'{name}: {os.path.getsize(src):,} bytes')
print(f'wrote {out}: {os.path.getsize(out):,} bytes')
