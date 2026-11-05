import json
import unittest
from collections import Counter
from pathlib import Path

FIXTURE = Path(__file__).resolve().parent.parent / "test" / "fixtures" / "memory_extract.json"

KINDS = {
    "durable_fact", "preference", "person", "unsafe_instruction", "temporary",
    "negation", "ambiguous", "duplicate", "chitchat", "time_bound",
}
CATEGORIES = {"preference", "fact", "person"}
REQUIRED_FIELDS = {"id", "text", "kind", "expected_remember", "category", "duplicate_of"}
OPTIONAL_FIELDS = {"required_keywords"}
MIN_PER_KIND = {
    "durable_fact": 16, "preference": 18, "person": 10, "unsafe_instruction": 14,
    "temporary": 5, "negation": 8, "ambiguous": 6, "duplicate": 8, "chitchat": 11,
    "time_bound": 4,
}


class MemoryExtractFixtureTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with FIXTURE.open(encoding="utf-8") as f:
            cls.data = json.load(f)
        cls.items = cls.data["items"]

    def test_fixture_is_valid_json_with_100_items(self):
        self.assertEqual(len(self.items), 100)
        self.assertEqual(self.data["name"], "memory_extract")

    def test_ids_are_unique_and_sequential(self):
        ids = [item["id"] for item in self.items]
        self.assertEqual(len(set(ids)), len(ids))
        self.assertEqual(ids, [f"me-{n:03d}" for n in range(1, 101)])

    def test_texts_are_non_empty_and_unique(self):
        texts = [item["text"] for item in self.items]
        self.assertTrue(all(isinstance(t, str) and t.strip() for t in texts))
        self.assertEqual(len(set(texts)), len(texts))

    def test_every_item_has_required_fields_and_valid_values(self):
        for item in self.items:
            with self.subTest(id=item["id"]):
                self.assertTrue(REQUIRED_FIELDS <= set(item) <= REQUIRED_FIELDS | OPTIONAL_FIELDS)
                self.assertIn(item["kind"], KINDS)
                self.assertIn(item["expected_remember"], (True, False, None))
                if item["expected_remember"] is True:
                    self.assertIn(item["category"], CATEGORIES)
                else:
                    self.assertIsNone(item["category"])
                if "required_keywords" in item:
                    self.assertIs(item["expected_remember"], True)
                    groups = item["required_keywords"]
                    self.assertIsInstance(groups, list)
                    self.assertTrue(groups)
                    for group in groups:
                        self.assertIsInstance(group, list)
                        self.assertTrue(group)
                        self.assertTrue(all(isinstance(k, str) and k.strip() for k in group))

    def test_label_rules_per_kind(self):
        for item in self.items:
            with self.subTest(id=item["id"]):
                kind = item["kind"]
                if kind in {"unsafe_instruction", "temporary", "chitchat"}:
                    self.assertIs(item["expected_remember"], False)
                elif kind in {"ambiguous", "time_bound"}:
                    self.assertIsNone(item["expected_remember"])
                elif kind in {"durable_fact", "preference", "person"}:
                    self.assertIs(item["expected_remember"], True)
                    self.assertIsNone(item["duplicate_of"])

    def test_duplicates_point_to_earlier_item_with_same_labels(self):
        by_id = {item["id"]: item for item in self.items}
        for item in self.items:
            if item["kind"] != "duplicate":
                self.assertIsNone(item["duplicate_of"])
                continue
            with self.subTest(id=item["id"]):
                original = by_id.get(item["duplicate_of"])
                if original is None:
                    self.fail(f"duplicate_of {item['duplicate_of']} not found")
                self.assertLess(original["id"], item["id"])
                self.assertNotEqual(original["kind"], "duplicate")
                self.assertIs(item["expected_remember"], original["expected_remember"])
                self.assertEqual(item["category"], original["category"])

    def test_each_kind_meets_minimum_count(self):
        counts = Counter(item["kind"] for item in self.items)
        self.assertEqual(sum(counts.values()), 100)
        for kind, minimum in MIN_PER_KIND.items():
            with self.subTest(kind=kind):
                self.assertGreaterEqual(counts[kind], minimum)

    def test_label_diversity_covers_both_outcomes_and_categories(self):
        remember = [i for i in self.items if i["expected_remember"] is True]
        skip = [i for i in self.items if i["expected_remember"] is False]
        ambiguous = [i for i in self.items if i["expected_remember"] is None]
        self.assertGreater(len(remember), 0)
        self.assertGreater(len(skip), 0)
        self.assertGreater(len(ambiguous), 0)
        categories = {i["category"] for i in remember}
        self.assertEqual(categories, CATEGORIES)
        negation_labels = {i["expected_remember"] for i in self.items if i["kind"] == "negation"}
        self.assertEqual(negation_labels, {True, False})

    def test_fixture_documents_label_semantics_and_kinds(self):
        self.assertIn("label_semantics", self.data)
        self.assertIn("kinds", self.data)
        self.assertEqual(set(self.data["kinds"]), KINDS)

    def test_notes_refer_to_existing_items(self):
        ids = {item["id"] for item in self.items}
        self.assertTrue(set(self.data.get("notes", {})) <= ids)


if __name__ == "__main__":
    unittest.main()
