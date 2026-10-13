# On-device performance and reliability validation

Use a physical Android phone with the pinned Qwen3-0.6B Q4_0 model. Desktop widget tests do not measure native inference, alarm delivery, thermal throttling, or Android process lifecycle.

## Record the environment

Record phone/SoC, Android version, RAM, app commit, model checksum, build mode, battery level, power-saving mode, and whether the phone is warm. Use a release or profile build for user-facing timing. Keep the same model and request set when comparing changes.

## Request set

Run each case at least ten times; report median and 95th percentile, including failures. Use a disposable test chat and explicitly named test tasks.

| Case | Check |
|---|---|
| `hello` | Immediate greeting route or short model response; no task writes |
| `add task benchmark buy milk` | Exactly one saved task; measure send-to-confirmation |
| `what tasks do I have?` | Database-backed answer includes tasks beyond the first ten |
| `what tasks do I have tomorrow?` | Correct local-day bounds |
| `help me plan my day` | Actual relevant tasks reach the response |
| `complete task benchmark buy milk` | Unique-title resolution; duplicate titles request clarification |
| A short casual question | Time to first visible text and time to full response |
| Follow-up after more than 60 seconds idle | Same conversation retains context |
| Long conversation and oversized input | Bounded context or explicit input error; no silent misleading fallback |
| Stop during generation, then immediately send again | Cancelled turn never executes a tool; new request receives only its own tokens |

Measure cold start separately from an already-loaded model. Repeat the warm set after several minutes of use to expose thermal effects. Record context preparation, native queue/load, prompt processing, cached tokens, first token, generation, database/action execution, and end-to-end time where available. Never log prompts, personal memories, or generated text in production timing logs.

## Initial targets, not measured claims

- Supported deterministic task commands: under 500 ms send-to-confirmation on the reference phone.
- Model requests: compare first visible text and complete-response latency independently; streaming alone does not reduce prompt-processing cost.
- No cancelled or malformed tool call changes data.
- No duplicate writes after retrying a failed follow-up operation.
- Accuracy must not regress when reducing prompt size or changing native settings.

## Reliability checklist

1. Create two chats, switch between them, restart the app, and reopen each. Verify history and context remain separate. Deleting a chat must require confirmation and leave tasks/memories unchanged.
2. Create/edit/complete a task in the UI and in chat. Verify the other screen and home-screen widget refresh.
3. Deny notification/exact-alarm permissions, create a reminder, then grant permission and reopen the app. Verify scheduling state and recovery are honest. Test edit, cancel, reboot, and app relaunch.
4. Open the widget assistant while the main app has an active chat. Close either surface during generation and verify the other remains usable.
5. Save an explicit personal memory and immediately terminate/reopen the app. Verify acknowledgement only follows persistence.
6. Test keyboard open, large text, narrow phone width, and wide/tablet sidebar.

## Native tuning experiments

Benchmark supported CPU kernels and thread counts with the same prompts. Do not raise the global ARM instruction baseline without checking every supported device. Runtime backend variants require correct native library packaging and device tests. Compare quantizations using action accuracy as well as latency and RAM. GPU/NPU backends and a model change are follow-up experiments, not assumed improvements.
