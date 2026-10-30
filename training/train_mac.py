#!/usr/bin/env python3
"""LoRA fine-tune of Qwen3-0.6B on an Apple-silicon Mac (MPS), no Colab needed.

Usage: python3 -I train_mac.py WORK_DIR [--epochs N] [--max-steps N] [--eval-only ADAPTER]
WORK_DIR holds data/train.jsonl + data/val.jsonl (build_dataset.py) and bundle/*.jsonl
(the unzipped corenyth_training_bundle.zip). Writes WORK_DIR/lora (adapter) and, after the
evaluation, WORK_DIR/merged (full model for convert_hf_to_gguf.py).
Same recipe as colab_cells.py: r=32, alpha=32, all projections, lr 2e-4 cosine, loss only on
the completion, prompts byte-identical to the app's.
"""
import argparse
import collections
import json
import os
import random
import re
import sys
import time

import torch
from peft import LoraConfig, PeftModel, get_peft_model
from transformers import AutoModelForCausalLM, AutoTokenizer

ap = argparse.ArgumentParser()
ap.add_argument('work')
ap.add_argument('--model', default='Qwen/Qwen3-0.6B')
ap.add_argument('--epochs', type=float, default=2.0)
ap.add_argument('--max-steps', type=int, default=0)
ap.add_argument('--max-len', type=int, default=2048)
ap.add_argument('--micro', type=int, default=2)
ap.add_argument('--accum', type=int, default=8)
ap.add_argument('--lr', type=float, default=2e-4)
ap.add_argument('--eval-only')
args = ap.parse_args()
W = args.work
dev = 'mps'
torch.manual_seed(8426)


def rows(p):
    return [json.loads(l) for l in open(os.path.join(W, p), encoding='utf-8')]


tok = AutoTokenizer.from_pretrained(args.model)
model = AutoModelForCausalLM.from_pretrained(args.model, torch_dtype=torch.bfloat16).to(dev)
if args.eval_only:
    model = PeftModel.from_pretrained(model, args.eval_only)
else:
    model = get_peft_model(model, LoraConfig(
        r=32, lora_alpha=32, lora_dropout=0.0, bias='none', task_type='CAUSAL_LM',
        target_modules=['q_proj', 'k_proj', 'v_proj', 'o_proj', 'gate_proj', 'up_proj', 'down_proj']))
model.print_trainable_parameters()

MOODS = {'calm', 'happy', 'excited', 'supportive', 'concerned', 'curious', 'unknown'}
TRUNC = 0


def encode(r):
    global TRUNC
    p = tok(r['prompt'], add_special_tokens=False)['input_ids']
    c = tok(r['completion'], add_special_tokens=False)['input_ids']
    if len(p) + len(c) > args.max_len:
        TRUNC += 1
    ids = (p + c)[:args.max_len]
    return ids, ([-100] * len(p) + c)[:args.max_len]


@torch.no_grad()
def run(prompt, max_new):
    ids = torch.tensor([tok(prompt, add_special_tokens=False)['input_ids']]).to(dev)
    out = model.generate(input_ids=ids, max_new_tokens=max_new, do_sample=False,
                         pad_token_id=tok.pad_token_id or tok.eos_token_id)
    return tok.decode(out[0][ids.shape[1]:], skip_special_tokens=True).strip()


def evaluate(kind, val, n, show=6):
    model.eval()
    rs = list(val[kind])
    random.Random(1).shuffle(rs)
    stats, confusion = collections.Counter(), collections.Counter()
    for i, r in enumerate(rs[:n]):
        text = run(r['prompt'], 160 if kind == 'plan' else 140).split('<|im_end|>')[0].strip()
        want = json.loads(r['completion'].replace('<|im_end|>', ''))
        try:
            got = json.loads(text)
            stats['valid_json'] += 1
        except Exception:
            got = None
        if isinstance(got, dict):
            e = got.get('emotion')
            env = (isinstance(e, dict) and e.get('mood') in MOODS and
                   all(isinstance(e.get(k), (int, float)) and 0 <= e[k] <= 1 for k in ('intensity', 'confidence')))
            stats['envelope_ok'] += env
            stats['mood_ok'] += bool(env and e['mood'] == want['emotion']['mood'])
            confusion[(want['emotion']['mood'], e.get('mood') if isinstance(e, dict) else None)] += 1
            if kind == 'plan':
                stats['intent_ok'] += got.get('intent') == want['intent']
                stats['ref_ok'] += ('ref' not in want) or got.get('ref') == want['ref']
                reply = got.get('reply') or ''
                stats['reply_present'] += bool(reply)
                stats['reply_le12_words'] += 0 < len(reply.split()) <= 12
            else:
                reply = got.get('text') or ''
                stats['text_present'] += bool(reply)
                stats['no_em_dash'] += '—' not in reply
        if i < show:
            tone = re.search(r'Reply tone: (\w+)', r['prompt']).group(1)
            msg = re.search(r'Message: (.*) /no_think', r['prompt'])
            print(f'[{tone}] {msg.group(1) if msg else ""}\n    -> {text[:220]}', flush=True)
    wrong = [(k, v) for k, v in confusion.most_common() if k[0] != k[1]][:8]
    return {k: f'{v}/{n}' for k, v in sorted(stats.items())}, 'mood mix-ups (want, got):', wrong


plan_va, mood_va, rep_va = rows('data/val.jsonl'), rows('bundle/mood_val.jsonl'), rows('bundle/reply_val.jsonl')
VAL = {'plan': plan_va + mood_va, 'reply': rep_va}

if not args.eval_only:
    train = rows('data/train.jsonl') + rows('bundle/mood_train.jsonl') + rows('bundle/reply_train.jsonl')
    random.Random(8426).shuffle(train)
    enc = [encode(r) for r in train]
    print(len(enc), 'train rows;', TRUNC, 'longer than', args.max_len, 'tokens', flush=True)
    per_step = args.micro * args.accum
    total = args.max_steps or int(len(enc) * args.epochs / per_step)
    warm = max(1, int(0.03 * total))
    params = [p for p in model.parameters() if p.requires_grad]
    for p in params:
        p.data = p.data.float()           # adapters train in fp32, base stays bf16
    opt = torch.optim.AdamW(params, lr=args.lr, weight_decay=0.0)
    sched = torch.optim.lr_scheduler.LambdaLR(
        opt, lambda s: (s + 1) / warm if s < warm else 0.5 * (1 + __import__('math').cos(
            __import__('math').pi * (s - warm) / max(1, total - warm))))
    model.train()
    order, pos, t0 = [], 0, time.time()
    for step in range(total):
        loss_sum = 0.0
        for _ in range(args.accum):
            if pos + args.micro > len(order):
                order = list(range(len(enc)))
                random.shuffle(order)
                pos = 0
            batch = [enc[i] for i in order[pos:pos + args.micro]]
            pos += args.micro
            L = max(len(x[0]) for x in batch)
            ids = torch.tensor([x[0] + [tok.pad_token_id] * (L - len(x[0])) for x in batch]).to(dev)
            lab = torch.tensor([x[1] + [-100] * (L - len(x[1])) for x in batch]).to(dev)
            att = torch.tensor([[1] * len(x[0]) + [0] * (L - len(x[0])) for x in batch]).to(dev)
            with torch.autocast('mps', dtype=torch.bfloat16):
                # lm_head only where there is loss (the completion): full-vocab logits for a
                # 1.4k-token prompt would not fit in memory
                inner = model.base_model.model
                h = inner.model(input_ids=ids, attention_mask=att).last_hidden_state[:, :-1]
                tgt = lab[:, 1:]
                sel = tgt != -100
                logits = inner.lm_head(h[sel]).float()
                loss = torch.nn.functional.cross_entropy(logits, tgt[sel]) / args.accum
            loss.backward()
            loss_sum += loss.item()
        torch.nn.utils.clip_grad_norm_(params, 1.0)
        opt.step(); sched.step(); opt.zero_grad(set_to_none=True)
        el = time.time() - t0
        if step % 5 == 0 or step == total - 1:
            print(f'step {step + 1}/{total} loss {loss_sum:.4f} lr {sched.get_last_lr()[0]:.2e} '
                  f'{el / (step + 1):.1f}s/step eta {(total - step - 1) * el / (step + 1) / 60:.0f} min', flush=True)
        if (step + 1) % 100 == 0:
            model.save_pretrained(os.path.join(W, 'lora'))
    model.save_pretrained(os.path.join(W, 'lora'))

print('PLAN  :', evaluate('plan', VAL, 80), flush=True)
print('REPLY :', evaluate('reply', VAL, 50), flush=True)
merged = model.merge_and_unload()
merged = merged.to(torch.bfloat16)
out = os.path.join(W, 'merged')
merged.save_pretrained(out, safe_serialization=True)
tok.save_pretrained(out)
print('saved merged model to', out, flush=True)
