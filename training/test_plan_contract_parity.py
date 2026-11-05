"""Host checks for exported plan prompts and contract semantics.

Set PROMPT_EXPORT_PATH to the JSON written by export_prompts_test.dart.
The training renderer implements plan-v1 and plan-v2: both share the plan
renderer and differ only in the system string (PLAN_SYSTEM vs PLAN_SYSTEM_V2).
Each is compared byte-for-byte with the app's export.
"""
import json
import os
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_dataset as dataset


EXPORT_PATH = os.environ.get("PROMPT_EXPORT_PATH")
ROOT = Path(__file__).resolve().parent.parent


class PlanContractParityTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.export = json.loads(Path(EXPORT_PATH).read_text(encoding="utf-8")) if EXPORT_PATH else None

    def require_export(self):
        if self.export is None:
            self.skipTest("set PROMPT_EXPORT_PATH to a Dart-exported prompt JSON")

    def test_existing_v1_renderer_parity(self):
        self.require_export()
        dataset.check(EXPORT_PATH)

    def test_v2_system_equals_export(self):
        self.require_export()
        self.assertEqual(dataset.PLAN_SYSTEM_V2, self.export["planSystemV2"])
        self.assertNotEqual(dataset.PLAN_SYSTEM_V2, dataset.PLAN_SYSTEM)

    def test_v2_samples_byte_identical(self):
        self.require_export()
        s = self.export["samples"]
        now = dataset.datetime(2026, 10, 20, 14, 5)
        full = dataset.render_v2("remind me to call mom at 5pm", now,
                                 "#3 buy milk\n#7 meeting (due tomorrow (Wed 21 Oct) at 3:00 PM)", "loving",
                                 dataset.personal_context("Asha", "teacher", "loving"),
                                 ["Last task mentioned: #3 buy milk"],
                                 'task "dentist" still needs a time', ["User likes tea"])
        self.assertEqual(full, s["planV2Full"])
        empty = dataset.render_v2("hi", dataset.datetime(2026, 1, 4, 9, 0), "(none)", "professional",
                                  dataset.personal_context("", "", "professional"))
        self.assertEqual(empty, s["planV2Empty"])
        no_tone = dataset.render_v2("hi", dataset.datetime(2026, 1, 4, 9, 0), "(none)", None)
        self.assertEqual(no_tone, s["planV2NoTone"])

    def test_v1_render_unchanged_and_differs_from_v2(self):
        self.require_export()
        s = self.export["samples"]
        now = dataset.datetime(2026, 10, 20, 14, 5)
        args = ("remind me to call mom at 5pm", now,
                "#3 buy milk\n#7 meeting (due tomorrow (Wed 21 Oct) at 3:00 PM)", "loving",
                dataset.personal_context("Asha", "teacher", "loving"),
                ["Last task mentioned: #3 buy milk"],
                'task "dentist" still needs a time', ["User likes tea"])
        v1 = dataset.render(*args)
        self.assertEqual(v1, s["planFull"])
        self.assertEqual(v1, dataset.render(*args, contract="plan-v1"))
        v2 = dataset.render_v2(*args)
        self.assertNotEqual(v1, v2)
        self.assertEqual(v2, dataset.render(*args, contract="plan-v2"))
        self.assertEqual(v1.replace(dataset.PLAN_SYSTEM, dataset.PLAN_SYSTEM_V2, 1), v2)
        self.assertNotEqual(s["planFull"], s["planV2Full"])

    def test_contract_intents_authorizations_and_field_order(self):
        self.require_export()
        c = self.export["contracts"]
        self.assertEqual(c["v1"], "plan-v1")
        self.assertEqual(c["v2"], "plan-v2")
        v1 = ["create_task", "create_reminder", "complete", "delete", "postpone",
              "list", "recall", "answer_pending", "cancel_pending", "chat"]
        v2_only = ["progress", "outcome", "details"]
        self.assertEqual(c["v1Intents"], v1)
        self.assertEqual(c["v2Intents"], v1 + v2_only)
        self.assertEqual(c["v2OnlyIntents"], v2_only)
        self.assertEqual(c["v2Authorizations"],
                         ["request", "statement", "question", "hypothetical", "negated"])
        # Renderer completion order follows semantic.dart's grammar: mood,
        # intent, optional intent fields in canonical order, auth/negated, reply.
        fields = {"create_task": ["title", "when"],
                  "create_reminder": ["title", "when", "multiple", "follow_up"],
                  "complete": ["title", "ref"], "delete": ["title", "ref"],
                  "postpone": ["title", "ref", "when"], "list": ["range"],
                  "recall": ["title"], "answer_pending": ["when"],
                  "cancel_pending": [], "chat": []}
        for intent, optional in fields.items():
            expected_v1 = ["emotion", "intent", *optional, "negated", "reply"]
            expected_v2 = ["emotion", "intent", *optional, "authorization", "reply"]
            self.assertEqual(expected_v1[0:2], ["emotion", "intent"])
            self.assertEqual(expected_v2[-2:], ["authorization", "reply"])
            self.assertIn(intent, c["v1Grammar"])
            self.assertIn(intent.replace("_", "-"), c["v2Grammar"])
        for intent, allowed in {"progress": ["ref"], "outcome": ["ref"],
                                "details": ["ref", "title", "when"]}.items():
            self.assertIn(intent, v2_only)
            self.assertTrue(allowed)


if __name__ == "__main__":
    unittest.main()
