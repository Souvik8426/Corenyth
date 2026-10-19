Read docs/plans/reliability-workflow/BRIEF.md. Workflow run directory: /var/folders/0y/8bj6ywhx5435lj6bcqbl4_th0000gn/T/wf_corenyth_reliability_rjvflfx_
Assigned stage: P5
Read accepted predecessor reports in docs/plans/reliability-workflow/ before editing.

### P5 — qualify the model and release on the phone (depends P1–P4)

Run the frozen corpus through actual native inference with the same prompt/grammar/settings as the app. Run 0.6B and 1.7B separately when the phone supports them, and run a forced-unavailable model mode. Report assisted end-to-end success and model-only plan accuracy separately so fallback does not conceal model weaknesses.

Run physical-device scenarios: exact screenshot request; reminder fires screen-off; optional follow-up; completion cancels it; cross-chat memory; process restart; reboot recovery; permission denial/re-enable; model-load failure; cancellation and immediate new turn. Use a release/profile build and disposable test data.

Gate: acceptance thresholds below are met, evidence is attached, build identity is recorded, and known remaining gaps are explicit. A build or unit-test pass alone cannot close P5.


Additional stage requirements:
Run complete automated software validation and prepare/run real-native evaluator where feasible. No simulated Qwen scoring. Without physical phone/model access produce a reproducible harness, evaluation report with NOT RUN entries and specific remaining commands; mark stage blocked or partial, never passed. Do not install APK or modify phone without explicit user direction.

Write /var/folders/0y/8bj6ywhx5435lj6bcqbl4_th0000gn/T/wf_corenyth_reliability_rjvflfx_/P5-DONE.json and the repository stage report when finished. Work on this stage only and stop.

Aggregate every deferred device obligation from P0–P4 into the final checklist. Separate software-complete from product-verified. Final P5 acceptance requires physical-device evidence; the orchestrator must leave P5 pending/partial if it is absent.

Build identity: generate a deterministic digest of relevant app/Dart/native source paths and content for the dirty release candidate, record it alongside base git revision and prompt fingerprint, and use a non-secret build define. A baseline git SHA plus an unrecorded dirty tree is insufficient to identify measured behavior. Parent already captured basic phone inventory in device-inventory.json; do not call those fields unknown, but installed source identity, model/turn evidence and behavioral checks still need evidence. Do not make unrelated version changes merely to label the candidate.

Evaluation oracle caution: do not shift every expected timestamp by a uniform offset for device runs. Named calendar dates, weekdays, daily wall-clock times and relative durations have different semantics. Prefer a fixed-clock evaluation session with isolated test DB and non-delivering scheduler while using the real native model; then test actual notification delivery separately against actual submission time. Document unsupported oracle semantics as not evaluated rather than accidentally scoring them as success. Test the scorer with deliberately wrong outcomes; schema validation is not an accuracy evaluator.

Parent read-only inventory now confirms installed APK SHA256 = 9bc36a7506066e0f6b4cab4574ac23b429da48dc681d0fe34b3d4b90d2df21e3, exactly matching P0's pre-repair APK whose 26 embedded lib sources matched baseline c1d1ada. See device-inventory.json. Installed baseline source identity is therefore established; repaired candidate is NOT installed. Do not report installed identity as wholly unknown or imply the code changes already affect the phone.
