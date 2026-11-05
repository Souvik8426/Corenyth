import json
import random
import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_dataset as dataset


class Mb8PlanRowsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        dataset.init_banks()

    def message(self, row):
        match = re.search(r"Message: (.*?) /no_think", row["prompt"])
        if match is None:
            self.fail("rendered plan prompt has no Message field")
        return match.group(1)

    def test_all_list_templates_are_single_task_and_markup_free(self):
        first = dataset.gen_list_item(random.Random(41))
        second = dataset.gen_list_item(random.Random(41))
        self.assertEqual(first, second)
        msg = self.message(first)
        plan = json.loads(first["completion"].removesuffix("<|im_end|>"))
        self.assertNotRegex(msg, r"^(?:[-*+]|\d+[.)]|\[.\])\s*")
        self.assertNotRegex(msg.lower(), r"^(?:add|create|make|put|remember to)\b")
        self.assertFalse(re.search(r"[`*_~#]", msg))
        self.assertEqual(plan["intent"], "create_task")
        self.assertEqual(plan["title"].lower(), msg.lower())
        self.assertNotIn("multiple", plan)
        self.assertEqual(first["tag"], "g:list_item")
        for template in dataset.LIST_ITEM_TEMPLATES:
            with self.subTest(template=template):
                title = dataset.strip_list_markup(template)
                self.assertNotRegex(title, r"^(?:[-*+]|\d+[.)]|\[.\])\s*")
                self.assertFalse(re.search(r"[`*_~#]", title))
                self.assertTrue(title)

    def test_status_notes_are_valid_for_declared_v1_contract(self):
        first = dataset.gen_status_note(random.Random(73))
        second = dataset.gen_status_note(random.Random(73))
        self.assertEqual(first, second)
        plan = json.loads(first["completion"].removesuffix("<|im_end|>"))
        self.assertEqual(plan["intent"], "chat")
        self.assertNotIn("title", plan)
        self.assertNotIn("ref", plan)
        self.assertNotIn("multiple", plan)
        self.assertEqual(first["tag"], "g:progress")
        self.assertIn(plan["intent"], ("chat", "create_task", "create_reminder", "complete",
                                        "delete", "postpone", "list", "recall",
                                        "answer_pending", "cancel_pending"))
        self.assertRegex(self.message(first).lower(), r"unconfirmed|on hold|waiting on|delayed")
        self.assertIn(plan["reply"], sum(dataset.CHAT["thanks"].values(), []))
        self.assertNotIn(plan["reply"], sum(dataset.CHAT["offline"].values(), []))


if __name__ == "__main__":
    unittest.main()
