import json
import tempfile
import unittest
from pathlib import Path

from evaluate_memory_extract import EvaluationError, load_jsonl, parse_prediction, score


class MemoryExtractEvaluationTest(unittest.TestCase):
    def setUp(self):
        self.items = [
            {"id": "a", "expected_remember": True, "category": "fact", "duplicate_of": None,
             "required_keywords": [["red meat"], ["not", "never"]]},
            {"id": "b", "expected_remember": False, "category": None, "duplicate_of": None},
            {"id": "c", "expected_remember": True, "category": "preference", "duplicate_of": "a"},
            {"id": "d", "expected_remember": None, "category": None, "duplicate_of": None},
        ]

    def test_strict_memory_contract(self):
        self.assertEqual(parse_prediction('{"remember":false}'), (False, None, None))
        self.assertEqual(parse_prediction('{"remember":true,"memory":"Not red meat","category":"fact"}'),
                         (True, "Not red meat", "fact"))
        for raw in ('[]', '{"remember":1}', '{"remember":false,"memory":"x"}',
                    '{"remember":true,"memory":" ","category":"fact"}',
                    '{"remember":true,"memory":"x","category":"other"}',
                    '{"remember":true,"memory":"x","category":"fact","extra":0}'):
            with self.subTest(raw=raw), self.assertRaises(EvaluationError):
                parse_prediction(raw)

    def test_scores_false_positives_precision_coverage_and_duplicate_views(self):
        predictions = {
            "a": (True, "not red meat", "fact"),
            "b": (True, "unsupported", "fact"),
            "c": (False, None, None),
            "d": (True, "ignored", "fact"),
        }
        result = score(self.items, predictions)
        full = result["full"]
        self.assertEqual((full["true_positive"], full["false_positive"], full["false_negative"]), (1, 1, 1))
        self.assertEqual(full["precision"], 1 / 2)
        self.assertEqual(full["coverage"], 1 / 2)
        self.assertEqual(full["required_content_errors_on_true_positives"], 0)
        unique = result["duplicate_excluded"]
        self.assertEqual(unique["scored"], 2)
        self.assertEqual(unique["false_positive"], 1)
        self.assertEqual(result["excluded_null_labels"], 1)

    def test_required_content_and_category_errors_are_reported(self):
        result = score(self.items, {
            "a": (True, "meat", "preference"), "b": (False, None, None),
            "c": (True, "okay", "preference"), "d": (False, None, None),
        })["duplicate_excluded"]
        self.assertEqual(result["category_errors_on_true_positives"], 1)
        self.assertEqual(result["required_content_errors_on_true_positives"], 1)

    def test_jsonl_requires_exact_complete_unique_fixture_ids(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "pred.jsonl"
            expected = {"a": self.items[0], "b": self.items[1]}
            path.write_text(json.dumps({"id": "a", "output": '{"remember":false}'}) + "\n", encoding="utf-8")
            with self.assertRaisesRegex(EvaluationError, "incomplete"):
                load_jsonl(path, expected)
            path.write_text("\n", encoding="utf-8")
            with self.assertRaises(EvaluationError):
                load_jsonl(path, expected)
            path.write_text("{}\n", encoding="utf-8")
            with self.assertRaises(EvaluationError):
                load_jsonl(path, expected)


if __name__ == "__main__":
    unittest.main()
