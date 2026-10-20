# Corenyth plan fine-tune: the Colab cells, in order (cell 1 is
# "%%writefile build_dataset.py" + training/build_dataset.py). Runtime: a GPU
# (T4 or better). Each "# %% cell N" block is pasted into its own cell.

# %% cell 2: setup, MASSIVE (en-US) and the training data
SETUP = r'''
!nvidia-smi --query-gpu=name,memory.total --format=csv
!pip -q install unsloth
!curl -sSL https://amazon-massive-nlu-dataset.s3.amazonaws.com/amazon-massive-dataset-1.0.tar.gz -o massive.tar.gz
!tar -xzf massive.tar.gz 1.0/data/en-US.jsonl
!mkdir -p data && python3 build_dataset.py 1.0/data/en-US.jsonl data && sha256sum build_dataset.py && wc -l data/*.jsonl
'''

# %% cell 3: model, LoRA, data encoding and the baseline evaluation
TRAIN = r'''
from unsloth import FastLanguageModel
import collections, json, random, re, torch
from datasets import Dataset
from transformers import TrainingArguments, Trainer, DataCollatorForSeq2Seq

MAX_LEN = 1024
model, tok = FastLanguageModel.from_pretrained('unsloth/Qwen3-0.6B', max_seq_length=MAX_LEN, dtype=None, load_in_4bit=False)
model = FastLanguageModel.get_peft_model(
    model, r=32, lora_alpha=32, lora_dropout=0, bias='none',
    target_modules=['q_proj', 'k_proj', 'v_proj', 'o_proj', 'gate_proj', 'up_proj', 'down_proj'],
    use_gradient_checkpointing='unsloth', random_state=8426)

def load(p):
    return [json.loads(l) for l in open(p, encoding='utf-8')]

train_rows, val_rows = load('data/train.jsonl'), load('data/val.jsonl')

def encode(r):
    # Prompt and completion tokenized apart, as the app sends the prompt and
    # the model continues it; only the completion carries loss.
    p = tok(r['prompt'], add_special_tokens=False)['input_ids']
    c = tok(r['completion'], add_special_tokens=False)['input_ids']
    ids = (p + c)[:MAX_LEN]
    return {'input_ids': ids, 'attention_mask': [1] * len(ids), 'labels': ([-100] * len(p) + c)[:MAX_LEN]}

def evaluate(rows, n=150, show=8):
    FastLanguageModel.for_inference(model)
    rows = list(rows)
    random.Random(1).shuffle(rows)
    stats = collections.Counter()
    for i, r in enumerate(rows[:n]):
        ids = tok(r['prompt'], add_special_tokens=False, return_tensors='pt').input_ids.to('cuda')
        out = model.generate(input_ids=ids, max_new_tokens=90, do_sample=False)
        text = tok.decode(out[0][ids.shape[1]:], skip_special_tokens=True).strip()
        want = json.loads(r['completion'].replace('<|im_end|>', ''))
        try:
            got = json.loads(text)
            stats['valid_json'] += 1
            stats['intent_ok'] += got.get('intent') == want['intent']
            stats['ref_ok'] += ('ref' not in want) or got.get('ref') == want['ref']
            stats['reply_present'] += bool(got.get('reply'))
        except Exception:
            pass
        if i < show:
            tone = re.search(r'Reply tone: (\w+)', r['prompt']).group(1)
            msg = re.search(r'Message: (.*) /no_think', r['prompt']).group(1)
            print(f'[{tone}] {msg}\n    -> {text[:170]}')
    FastLanguageModel.for_training(model)
    return {k: f'{v}/{n}' for k, v in sorted(stats.items())}

print('BEFORE fine-tune:', evaluate(val_rows))
'''

# %% cell 3b: train (the baseline above stays in memory), then evaluate again.
# transformers 5 dropped warmup_ratio, hence warmup_steps.
TRAIN_RUN = r'''
model.generation_config.max_length = None  # silences the max_length warning during evaluation
train_ds = Dataset.from_list([encode(r) for r in train_rows])
args = TrainingArguments(
    output_dir='out', per_device_train_batch_size=8, gradient_accumulation_steps=2, num_train_epochs=2,
    learning_rate=2e-4, lr_scheduler_type='cosine', warmup_steps=15, logging_steps=20, save_strategy='no',
    report_to='none', optim='adamw_8bit', seed=8426,
    bf16=torch.cuda.is_bf16_supported(), fp16=not torch.cuda.is_bf16_supported())
trainer = Trainer(model=model, args=args, train_dataset=train_ds,
                  data_collator=DataCollatorForSeq2Seq(tok, padding=True, label_pad_token_id=-100))
trainer.train()
AFTER = evaluate(val_rows)
print('AFTER fine-tune:', AFTER)
'''

# %% cell 4: save the LoRA adapter and export a merged Q4_0 GGUF (the app's quantization)
EXPORT = r'''
model.save_pretrained('corenyth-lora')
tok.save_pretrained('corenyth-lora')
model.save_pretrained_gguf('corenyth-gguf', tok, quantization_method='q4_0')
!find . -name "*.gguf" -size +10M -exec ls -la {} \;
!find . -name "*.gguf" -size +10M -exec sha256sum {} \;
'''
