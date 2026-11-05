"""Parse numeric LlamaBridge timing lines into per-request measurements.

Usage: python3 training/parse_llama_log.py run.log
"""

from __future__ import annotations

import argparse
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Optional


_TIMING = re.compile(
    r"prompt (?P<prompt>\d+) tok \((?P<reused>\d+) reused\) in "
    r"(?P<prompt_ms>\d+) ms; first token (?P<first_ms>-?\d+) ms; "
    r"generated (?P<generated>\d+) tok in (?P<gen_ms>\d+) ms"
    r"(?P<failed> \(failed\))?"
)


@dataclass(frozen=True)
class Measurement:
    line_number: int
    prompt_tokens: int
    reused_tokens: int
    reused_percent: float
    prefill_ms: int
    decode_tokens_per_second: Optional[float]
    generated_tokens: int
    decode_ms: int
    failed: bool


def parse_lines(lines: Iterable[str]) -> tuple[list[Measurement], list[int]]:
    """Return parsed timing records and 1-based line numbers without timing data."""
    measurements = []
    missing = []
    for line_number, line in enumerate(lines, 1):
        if "prompt " not in line or "tok (" not in line:
            continue
        match = _TIMING.search(line)
        if match is None:
            missing.append(line_number)
            continue
        values = match.groupdict()
        prompt = int(values["prompt"])
        generated = int(values["generated"])
        decode_ms = int(values["gen_ms"])
        measurements.append(
            Measurement(
                line_number=line_number,
                prompt_tokens=prompt,
                reused_tokens=int(values["reused"]),
                reused_percent=(100.0 * int(values["reused"]) / prompt) if prompt else 0.0,
                prefill_ms=int(values["prompt_ms"]),
                decode_tokens_per_second=(
                    generated * 1000.0 / decode_ms if decode_ms > 0 else None
                ),
                generated_tokens=generated,
                decode_ms=decode_ms,
                failed=values["failed"] is not None,
            )
        )
    return measurements, missing


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path, help="logcat output captured with -s LlamaBridge")
    args = parser.parse_args()
    try:
        with args.log.open(encoding="utf-8", errors="replace") as log_file:
            measurements, missing = parse_lines(log_file)
    except OSError as exc:
        parser.error(str(exc))

    print("request line prompt_tokens reused_pct prefill_ms decode_tok_s generated_tokens")
    for request, item in enumerate(measurements, 1):
        speed = "n/a" if item.decode_tokens_per_second is None else f"{item.decode_tokens_per_second:.2f}"
        failure = " failed" if item.failed else ""
        print(
            f"{request} {item.line_number} {item.prompt_tokens} {item.reused_percent:.2f} "
            f"{item.prefill_ms} {speed} {item.generated_tokens}{failure}"
        )
    if missing:
        print("Malformed timing lines: " + ", ".join(map(str, missing)))
    if not measurements:
        print("No timing records found.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
