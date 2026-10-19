# ml/

Python 3.11 pipeline for the in-house distilled model (handbook Phase 6): scenario generation,
LoRA fine-tuning, evaluation and conversion to WebLLM format.

```
ml/
  gen/        scenario generator, paraphraser, attack library
  data/       train.jsonl, val.jsonl, test.jsonl, handwritten_test.jsonl
  train/      sft.py, dpo.py, merge.py, configs/*.yaml
  eval/       eval_fp16.py, metrics.py
  convert/    convert.sh, model-card template
  requirements.txt
```

Set up the environment when Phase 6 starts:

```sh
py -3.11 -m venv ml/.venv          # Windows (python3.11 -m venv ml/.venv elsewhere)
ml/.venv/Scripts/activate          # Windows (source ml/.venv/bin/activate elsewhere)
pip install -r ml/requirements.txt
```

`ml/.venv`, `ml/data/raw` and `ml/checkpoints` are gitignored.
