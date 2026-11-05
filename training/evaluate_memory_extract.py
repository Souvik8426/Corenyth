#!/usr/bin/env python3
"""Score explicit model-output JSONL against the memory extraction fixture."""
import argparse
import json
import sys
from pathlib import Path

FIXTURE = Path(__file__).resolve().parent.parent / "test" / "fixtures" / "memory_extract.json"
CATEGORIES = {"preference", "fact", "person"}


class EvaluationError(ValueError):
    pass


def parse_prediction(raw):
    try:
        value = json.loads(raw)
    except (TypeError, json.JSONDecodeError) as exc:
        raise EvaluationError(f"invalid model JSON: {exc}") from exc
    if not isinstance(value, dict) or type(value.get("remember")) is not bool:
        raise EvaluationError("output must be an object with boolean remember")
    if value["remember"] is False:
        if set(value) != {"remember"}:
            raise EvaluationError("non-remember output must contain only remember")
        return False, None, None
    if set(value) != {"remember", "memory", "category"}:
        raise EvaluationError("remember output requires exactly remember, memory, category")
    memory, category = value["memory"], value["category"]
    if not isinstance(memory, str) or not memory.strip():
        raise EvaluationError("memory must be a non-empty string")
    if category not in CATEGORIES:
        raise EvaluationError("category must be preference, fact, or person")
    return True, memory.strip(), category


def load_jsonl(path, fixture_items):
    rows = {}
    try:
        lines = Path(path).read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        raise EvaluationError(f"cannot read predictions: {exc}") from exc
    if not lines:
        raise EvaluationError("prediction JSONL is empty")
    for number, line in enumerate(lines, 1):
        if not line.strip():
            raise EvaluationError(f"blank JSONL line {number}")
        try:
            row = json.loads(line)
        except json.JSONDecodeError as exc:
            raise EvaluationError(f"invalid JSON on line {number}: {exc}") from exc
        if not isinstance(row, dict) or set(row) != {"id", "output"}:
            raise EvaluationError(f"line {number} must contain exactly id and output")
        item_id = row["id"]
        if not isinstance(item_id, str) or item_id not in fixture_items:
            raise EvaluationError(f"unknown or invalid id on line {number}: {item_id!r}")
        if item_id in rows:
            raise EvaluationError(f"duplicate prediction for {item_id}")
        if not isinstance(row["output"], str):
            raise EvaluationError(f"output on line {number} must be a JSON string")
        rows[item_id] = parse_prediction(row["output"])
    expected = set(fixture_items)
    if set(rows) != expected:
        missing = sorted(expected - set(rows))
        raise EvaluationError(f"incomplete predictions: missing {len(missing)} IDs (e.g. {', '.join(missing[:5])})")
    return rows


def score(items, predictions):
    evaluated = [x for x in items if x["expected_remember"] is not None]
    result = {}
    for label, subset in (("full", evaluated), ("duplicate_excluded", [x for x in evaluated if not x["duplicate_of"]])):
        tp = fp = fn = 0
        category_errors = content_errors = 0
        for item in subset:
            remember, memory, category = predictions[item["id"]]
            expected = item["expected_remember"]
            if remember and not expected:
                fp += 1
            if expected and remember:
                tp += 1
                if category != item["category"]:
                    category_errors += 1
                groups = item.get("required_keywords", [])
                if any(not any(word.casefold() in memory.casefold() for word in group) for group in groups):
                    content_errors += 1
            if expected and not remember:
                fn += 1
        precision_den = tp + fp
        positive_total = tp + fn
        result[label] = {
            "scored": len(subset), "true_positive": tp, "false_positive": fp,
            "false_negative": fn,
            "precision": tp / precision_den if precision_den else None,
            "coverage": tp / positive_total if positive_total else None,
            "false_positive_rate": fp / (len(subset) - positive_total) if len(subset) > positive_total else None,
            "category_errors_on_true_positives": category_errors,
            "required_content_errors_on_true_positives": content_errors,
        }
    result["excluded_null_labels"] = sum(x["expected_remember"] is None for x in items)
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("predictions", help="JSONL rows: {\"id\": fixture ID, \"output\": raw model JSON string}")
    parser.add_argument("--fixture", default=str(FIXTURE))
    args = parser.parse_args(argv)
    try:
        fixture = json.loads(Path(args.fixture).read_text(encoding="utf-8"))
        items = fixture["items"]
        by_id = {item["id"]: item for item in items}
        if len(by_id) != len(items) or not items:
            raise EvaluationError("fixture IDs must be non-empty and unique")
        predictions = load_jsonl(args.predictions, by_id)
        print(json.dumps(score(items, predictions), indent=2, sort_keys=True))
        return 0
    except (OSError, KeyError, TypeError, json.JSONDecodeError, EvaluationError) as exc:
        print(f"evaluation failed: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
