Read docs/plans/reliability-workflow/BRIEF.md. Workflow run directory: /var/folders/0y/8bj6ywhx5435lj6bcqbl4_th0000gn/T/wf_corenyth_reliability_rjvflfx_
Assigned stage: P0
Read accepted predecessor reports in docs/plans/reliability-workflow/ before editing.

### P0 — establish a reproducible baseline (blocks acceptance claims)

Scope: diagnostic path in session/engine/model services; `docs/device-evaluation.md`; a local evaluation fixture directory.

Record installed APK identity versus checkout, phone/Android/RAM, selected and active model/checksum, load failure code, prompt/grammar version, and actual route for each turn. Capture the exact screenshot request with fixed-time tests, then in a disposable phone test profile/chat. Preserve user data. Verify toolchain and build reproducibility; identify missing setup explicitly.

Create a frozen evaluation corpus before changing prompts: at least 120 single-turn examples across scheduling, updates, lists, progress, memory, ambiguity, negation and general chat; at least 20 multi-turn scenarios. Reserve at least 30 single-turn cases as held-out variants. Include the user's historical failure cases. Keep expected state changes separate from preferred wording.

Gate: baseline report exists with failures classified and unrun checks marked unrun. No invented baseline percentages.


Additional stage requirements:
P0 owns baseline/evaluation artifacts and necessary diagnostic instrumentation ONLY; do not fix parser/routing/memory yet. Create real runnable fixture schemas with explicit expected state changes, a validator, and at least 120 distinct single-turn and 20 multi-turn cases. Freeze >=30 held-out single-turn cases with hashes; implementers must not tune prompts against held-out text. Avoid repetitive filler to meet counts. Record current test and toolchain baseline, not speculative results. Inspect model native diagnostics and capture build/phone evidence only where accessible without modifying the phone. Write a focused screenshot regression as a baseline failing case if tooling allows. Missing phone evidence must not prevent documenting the baseline honestly.

Write /var/folders/0y/8bj6ywhx5435lj6bcqbl4_th0000gn/T/wf_corenyth_reliability_rjvflfx_/P0-DONE.json and the repository stage report when finished. Work on this stage only and stop.
