import unittest

from parse_llama_log import parse_lines


class ParseLlamaLogTest(unittest.TestCase):
    def test_parses_actual_native_log_format_with_logcat_prefix(self):
        line = (
            "10-31 12:34:56.789 1234 1234 I LlamaBridge: "
            "prompt 1200 tok (900 reused) in 300 ms; first token 310 ms; "
            "generated 40 tok in 2000 ms"
        )
        records, malformed = parse_lines([line])
        self.assertEqual(malformed, [])
        self.assertEqual(len(records), 1)
        item = records[0]
        self.assertEqual(item.line_number, 1)
        self.assertEqual(item.prompt_tokens, 1200)
        self.assertEqual(item.reused_tokens, 900)
        self.assertAlmostEqual(item.reused_percent, 75.0)
        self.assertEqual(item.prefill_ms, 300)
        self.assertIsNotNone(item.decode_tokens_per_second)
        self.assertAlmostEqual(item.decode_tokens_per_second or 0.0, 20.0)
        self.assertEqual(item.generated_tokens, 40)
        self.assertEqual(item.decode_ms, 2000)
        self.assertFalse(item.failed)

    def test_failed_format_zero_values_and_unrelated_lines(self):
        lines = [
            "ordinary log line",
            "prompt 20 tok (0 reused) in 0 ms; first token -1 ms; generated 0 tok in 0 ms (failed)",
        ]
        records, malformed = parse_lines(lines)
        self.assertEqual(malformed, [])
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0].reused_percent, 0.0)
        self.assertEqual(records[0].prefill_ms, 0)
        self.assertIsNone(records[0].decode_tokens_per_second)
        self.assertTrue(records[0].failed)

    def test_missing_and_malformed_timing_lines_are_reported_by_line(self):
        lines = [
            "unrelated message",
            "prompt 12 tok (6 reused) in 10 ms; first token 11 ms; generated 2 tok in 100 ms",
            "prompt 8 tok (4 reused) in unknown ms; generated 3 tok",
        ]
        records, malformed = parse_lines(lines)
        self.assertEqual([item.line_number for item in records], [2])
        self.assertEqual(malformed, [3])

    def test_prompt_zero_does_not_divide_by_zero(self):
        line = "prompt 0 tok (0 reused) in 0 ms; first token -1 ms; generated 0 tok in 0 ms"
        records, malformed = parse_lines([line])
        self.assertEqual(malformed, [])
        self.assertEqual(records[0].reused_percent, 0.0)


if __name__ == "__main__":
    unittest.main()
