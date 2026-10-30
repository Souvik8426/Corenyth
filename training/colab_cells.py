# Corenyth fine-tune of Qwen3-0.6B (plan + reply contracts, mood envelope, four personalities):
# the Colab cells, in order. Runtime: a GPU (T4 or better). Each CELLn string is
# pasted into its own cell.
#
# Before cell 1, upload corenyth_training_bundle.zip to /content (left sidebar > Files).
# The bundle holds build_dataset.py, app_prompts.py, reply_banks.json and bundle/*.jsonl
# (the mood rows and the personality reply rows, built on the Mac by build_chat_rows.py).

CELL0 = r'''
# 1. Wait for corenyth_training_bundle.zip (upload it to /content), then unpack it
import os, time, zipfile
Z = 'corenyth_training_bundle.zip'
def stable(p):
    a = os.path.getsize(p); time.sleep(5)
    return a > 0 and a == os.path.getsize(p)
n = 0
while not (os.path.exists(Z) and stable(Z)):
    if n % 6 == 0:
        print('waiting for', Z, 'in /content (left sidebar > Files > Upload) ...')
    n += 1; time.sleep(10)
zipfile.ZipFile(Z).extractall('.')
print(sorted(os.listdir('.')), sorted(os.listdir('bundle')))
'''

CELL1 = r'''
# 2. Setup: GPU check, Unsloth, MASSIVE (en-US) and the plan rows
!nvidia-smi --query-gpu=name,memory.total --format=csv
!pip -q install --upgrade unsloth unsloth_zoo
!curl -sSL https://amazon-massive-nlu-dataset.s3.amazonaws.com/amazon-massive-dataset-1.0.tar.gz -o massive.tar.gz
!tar -xzf massive.tar.gz 1.0/data/en-US.jsonl
!mkdir -p data && python3 -I build_dataset.py 1.0/data/en-US.jsonl data && sha256sum build_dataset.py && wc -l data/*.jsonl
'''

CELL2 = r'''
# 3. Merge: plan rows + mood rows + personality reply rows (validation stays apart)
import json, random
def rows(p):
    return [json.loads(l) for l in open(p, encoding='utf-8')]
plan_tr, plan_va = rows('data/train.jsonl'), rows('data/val.jsonl')
mood_tr, mood_va = rows('bundle/mood_train.jsonl'), rows('bundle/mood_val.jsonl')
rep_tr, rep_va = rows('bundle/reply_train.jsonl'), rows('bundle/reply_val.jsonl')
train = plan_tr + mood_tr + rep_tr
random.Random(8426).shuffle(train)
with open('data/train_all.jsonl', 'w', encoding='utf-8') as f:
    f.write(''.join(json.dumps(r, ensure_ascii=False) + '\n' for r in train))
json.dump({'plan': plan_va + mood_va, 'reply': rep_va}, open('data/val_all.json', 'w', encoding='utf-8'), ensure_ascii=False)
print(len(plan_tr), 'plan +', len(mood_tr), 'mood +', len(rep_tr), 'reply =', len(train), 'train rows;',
      len(plan_va) + len(mood_va), 'plan val,', len(rep_va), 'reply val')
'''

CELL3 = r'''
# 4. Model, LoRA, encoding and the evaluator (plan and reply contracts, loss on the completion only)
from unsloth import FastLanguageModel
import collections, json, random, re, torch
from datasets import Dataset
from transformers import TrainingArguments, Trainer, DataCollatorForSeq2Seq

MAX_LEN = 2048   # the plan prompt alone is ~1.2k tokens; 1024 would cut the completion off
model, tok = FastLanguageModel.from_pretrained('unsloth/Qwen3-0.6B', max_seq_length=MAX_LEN, dtype=None, load_in_4bit=False)
model = FastLanguageModel.get_peft_model(
    model, r=32, lora_alpha=32, lora_dropout=0, bias='none', random_state=8426,
    target_modules=['q_proj', 'k_proj', 'v_proj', 'o_proj', 'gate_proj', 'up_proj', 'down_proj'])
BOS = []   # Qwen3 has no BOS token

train_rows = [json.loads(l) for l in open('data/train_all.jsonl', encoding='utf-8')]
VAL = json.load(open('data/val_all.json', encoding='utf-8'))
MOODS = {'calm', 'happy', 'excited', 'supportive', 'concerned', 'curious', 'unknown'}
TRUNCATED = 0

def encode(r):
    # Prompt and completion tokenized apart, as the app sends the prompt and
    # the model continues it; only the completion carries loss.
    global TRUNCATED
    p = BOS + tok(r['prompt'], add_special_tokens=False)['input_ids']
    c = tok(r['completion'], add_special_tokens=False)['input_ids']
    if len(p) + len(c) > MAX_LEN:
        TRUNCATED += 1
    ids = (p + c)[:MAX_LEN]
    return {'input_ids': ids, 'attention_mask': [1] * len(ids), 'labels': ([-100] * len(p) + c)[:MAX_LEN]}

def run(prompt, max_new):
    ids = torch.tensor([BOS + tok(prompt, add_special_tokens=False)['input_ids']]).to('cuda')
    out = model.generate(input_ids=ids, max_new_tokens=max_new, do_sample=False)
    return tok.decode(out[0][ids.shape[1]:], skip_special_tokens=True).strip()

def evaluate(kind, n=150, show=6):
    FastLanguageModel.for_inference(model)
    rows = list(VAL[kind])
    random.Random(1).shuffle(rows)
    stats, confusion = collections.Counter(), collections.Counter()
    for i, r in enumerate(rows[:n]):
        text = run(r['prompt'], 160 if kind == 'plan' else 140)
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
            msg = re.search(r'Message: (.*) /no_think', r['prompt']).group(1)
            print(f'[{tone}] {msg}\n    -> {text[:220]}')
    FastLanguageModel.for_training(model)
    wrong = [(k, v) for k, v in confusion.most_common() if k[0] != k[1]][:8]
    return {k: f'{v}/{n}' for k, v in sorted(stats.items())}, 'mood mix-ups (want, got):', wrong

train_ds = Dataset.from_list([encode(r) for r in train_rows])
print(len(train_ds), 'rows;', TRUNCATED, 'longer than', MAX_LEN, 'tokens')
'''

CELL4 = r'''
# 4b. Train, then evaluate (transformers 5 dropped warmup_ratio, hence warmup_steps)
model.generation_config.max_length = None  # silences the max_length warning during evaluation
EPOCHS = 2   # 0.6B: expect well under 2 h on the T4; check the s/it of the first steps
MAX_STEPS = -1
args = TrainingArguments(
    output_dir='out', per_device_train_batch_size=4, gradient_accumulation_steps=4, num_train_epochs=EPOCHS, max_steps=MAX_STEPS,
    learning_rate=2e-4, lr_scheduler_type='cosine', warmup_steps=30, logging_steps=20,
    save_strategy='steps', save_steps=200, save_total_limit=1,
    report_to='none', optim='adamw_8bit', seed=8426,
    bf16=torch.cuda.is_bf16_supported(), fp16=not torch.cuda.is_bf16_supported())
trainer = Trainer(model=model, args=args, train_dataset=train_ds,
                  data_collator=DataCollatorForSeq2Seq(tok, padding=True, label_pad_token_id=-100))
trainer.train()
print('PLAN  :', evaluate('plan', n=80))
print('REPLY :', evaluate('reply', n=50))
'''

CELL5 = r'''
# 5. Save the LoRA adapter and export a merged Q4_0 GGUF (the app's quantization)
model.save_pretrained('corenyth-lora')
tok.save_pretrained('corenyth-lora')
model.save_pretrained_gguf('corenyth-gguf', tok, quantization_method='q4_0')
!find . -name "*.gguf" -size +10M -exec ls -la {} \;
!find . -name "*.gguf" -size +10M -exec sha256sum {} \;
'''

CELL6 = r'''
# 6. Download the fine-tuned GGUF
import os, glob
from google.colab import files
g = [p for p in glob.glob('corenyth-gguf*/*.gguf') if 'mmproj' not in p]
print(g)
files.download(max(g, key=os.path.getsize))
'''

CELLS = [CELL0, CELL1, CELL2, CELL3, CELL4, CELL5, CELL6]
