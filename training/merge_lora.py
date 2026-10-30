#!/usr/bin/env python3
"""Merges a PEFT LoRA adapter into a base model's safetensors, tensor by tensor.

Usage: python3 merge_lora.py BASE_DIR ADAPTER_DIR OUT_DIR
Each adapted weight becomes W + (alpha / r) * (B @ A), computed in float32 and stored in the
base dtype. Tokenizer and config files are copied from BASE_DIR. Used because the Colab runtime
(12 GB RAM) cannot convert the 5B-parameter Gemma 4 E2B to GGUF; a Mac with 24 GB can.
"""
import glob
import json
import os
import shutil
import sys

import torch
from safetensors import safe_open
from safetensors.torch import save_file

base_dir, adapter_dir, out_dir = sys.argv[1:4]
cfg = json.load(open(os.path.join(adapter_dir, 'adapter_config.json')))
scale = cfg['lora_alpha'] / cfg['r']
if cfg.get('use_rslora'):
    scale = cfg['lora_alpha'] / (cfg['r'] ** 0.5)

adapter = {}
with safe_open(os.path.join(adapter_dir, 'adapter_model.safetensors'), 'pt') as f:
    for k in f.keys():
        adapter[k] = f.get_tensor(k)
pairs = {}
for k in adapter:
    if '.lora_A.weight' in k:
        target = k.replace('base_model.model.', '', 1).replace('.lora_A.weight', '.weight')
        pairs[target] = (adapter[k], adapter[k.replace('lora_A', 'lora_B')])
print(f'{len(pairs)} adapted weights, scale {scale}')

os.makedirs(out_dir, exist_ok=True)
merged, seen = {}, set()
for path in sorted(glob.glob(os.path.join(base_dir, '*.safetensors'))):
    with safe_open(path, 'pt') as f:
        for k in f.keys():
            w = f.get_tensor(k)
            if k in pairs:
                a, b = pairs[k]
                delta = (b.float() @ a.float()) * scale
                assert delta.shape == w.shape, (k, delta.shape, w.shape)
                w = (w.float() + delta).to(w.dtype)
                seen.add(k)
            merged[k] = w.contiguous()
missing = set(pairs) - seen
assert not missing, f'adapter weights not found in the base: {sorted(missing)[:5]}'
save_file(merged, os.path.join(out_dir, 'model.safetensors'), metadata={'format': 'pt'})
for name in os.listdir(base_dir):
    p = os.path.join(base_dir, name)
    if os.path.isfile(p) and not name.endswith('.safetensors') and not name.startswith('.'):
        shutil.copy(p, out_dir)
# the base's index file would point at shards that no longer exist
idx = os.path.join(out_dir, 'model.safetensors.index.json')
if os.path.exists(idx):
    os.remove(idx)
print(f'merged {len(seen)} weights into {out_dir}')
