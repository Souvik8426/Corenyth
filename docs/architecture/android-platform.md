# Android platform

## Components

| Component | File | What it does |
|---|---|---|
| `MainActivity` | `android/app/src/main/kotlin/com/corenyth/assistant/MainActivity.kt` | Flutter host. Registers `assistant/native` and `assistant/llm`. |
| `VoiceSessionActivity` | `VoiceSessionActivity.kt` | Translucent window (`VoiceTheme`, `singleTask`, excluded from recents). Starts Dart on route `/voice`. |
| `WidgetProvider` / `CompactWidgetProvider` | `WidgetProvider.kt` | Task-list and companion widgets. Display reads SQLite without starting Flutter or the model. |
| `WidgetTaskService` | `WidgetTaskService.kt` | RemoteViews list adapter for all pending tasks. |
| `WidgetMascot` | `WidgetMascot.kt` | Generates floating/blinking frames for the compact widget's launcher-owned ViewFlipper. |
| `WidgetAddActivity` | `WidgetAddActivity.kt` | Translucent Flutter host for widget prompts; starts `/voice`, without opening the main home screen. |
| `LlamaBridge` | `LlamaBridge.kt` | The `assistant/llm` handler. See [llm-engine.md](llm-engine.md). |
| `ProactiveReceiver` | `Proactive.kt` | AlarmManager delivery, Done/Snooze actions, boot/time reconciliation; starts a headless Flutter engine when needed. |
| Notification permissions | `flutter_local_notifications` | Permission checks and test notification; old plugin schedules are cancelled during initialization. |

## Widgets

The sidebar's **Add home screen widget** action offers two choices. It calls `pinWidget` with
`compact: false` or `true` and asks the launcher to pin the corresponding provider (Android 8+
with a supporting launcher). Otherwise, add a widget from the launcher's widget picker.
Both layouts can be resized; actual cell dimensions depend on the launcher.

| Choice | Layout / metadata | Behavior |
|---|---|---|
| My tasks · 4 × 2 | `assistant_widget.xml` / `assistant_widget_info.xml` | Current launcher logo, remaining count, scrollable task list, completion circles, and “+”. |
| Companion · 2 × 2 | `compact_widget.xml` / `compact_widget_info.xml` | Larger animated mascot, top-right “+”, and bottom remaining count. No separate top-left logo. |

`WidgetTasks.read` queries every pending task, ordered by due date (undated last), priority descending,
and id. Rows show the title and an optional localized due date/time. Empty data displays “All clear”;
a missing or unreadable database displays a setup message instead of reporting zero tasks.

The compact mascot uses twelve cached bitmap frames in a `ViewFlipper`, at 160 ms intervals.
The launcher owns playback; there is no animation service, background polling loop, or model inference
for display. It is a native floating/blinking rendition of the companion, not the full Flutter emotion system.
Animation and sizing still need launcher-specific device verification.

### Prompt panel

“+” in either widget opens `WidgetAddActivity`, a translucent, recents-excluded activity using
`VoiceTheme` and the `/voice` Dart route. The route name is historical: this is **typed chat**, not speech.
It starts Flutter services and shows `ChatPage` directly, with an autofocus composer and an “Ask Corenyth”
header. The main app home screen is not opened. Android hosts the text input in this activity;
the launcher widget itself does not contain an editable field.

Input goes through `AppServices.newSession` → `AssistantSession.handle` → the shared interpreter,
validation, and tools. It is **not inserted directly as a task title**. For example, “Remind me to buy
groceries tomorrow at 6 pm” is interpreted as a request, with any required clarification and the final
reply shown in the same panel. Subsequent messages use the same session while the panel remains open.
The session uses the installed model when available and the app's existing rules fallback otherwise;
normal language-reliability limitations still apply. Conversation messages are persisted, and opening
a new panel creates a new chat. Close ends the session and dismisses the activity.

### Completion and refresh

A task's completion circle sends its id to `WidgetProvider`, which dispatches `widgetDone` through
`Proactive.run`. Dart calls `TaskRepo.complete` only for an existing pending task, so task-linked reminder
cancellation uses the repository's existing synchronization logic. This action may start a headless
Flutter engine, but does not invoke the model.

Assistant tool changes call `NativeBridge.refreshWidget`. `refreshAll` updates both providers and
invalidates the task-list adapter; completion also refreshes widgets through `Proactive.run`.
The metadata additionally requests periodic updates every 30 minutes. See the
[phone verification checklist](../guides/build-and-run.md#widget-verification-on-a-phone).

## Reminders

- `AlarmReminderScheduler` (Dart) arms native AlarmManager alarms through `assistant/alarms`, using exact delivery when permitted.
- Alarms are cancelled with the reminder id.
- Startup/resume reconciles missed alerts and future schedules; boot, clock, timezone and app-update broadcasts also reconcile. Android force-stop blocks delivery until the user opens the app again.
- Permissions requested at start: notifications and exact alarms. The runtime state (`areNotificationsEnabled`,
  `canScheduleExactNotifications`) is checked at startup and when a reminder is created; if either is off the reply
  and the Chat banner say so instead of promising the reminder will ring.
- Delivery re-reads task state and saves a unique occurrence in the main chat before notifying. Done cancels pending task reminders; Snooze adds a ten-minute alert without moving the deadline. Taps open the relevant task or main chat.
- Evening review runs thirty minutes before DND when follow-ups are enabled. No saved DND defaults to 22:00–07:00. Optional messages respect quiet hours; explicit event alarms retain their existing behavior.
- A closed-app job starts the `proactiveMain` Dart entrypoint with a nine-second native deadline. Background text uses factual templates; Qwen continues the conversation when opened. On timeout, a still-current event alarm can show its saved title, and a review re-arms the next day. Cold-start speed and manufacturer battery restrictions require phone testing.
- Delivery runs in the dedicated `:proactive` Android process with its own SQLite worker pool. WAL permits foreground reads while delivery writes. This avoids a same-worker deadlock between two database connections during startup. One headless engine is retained per delivery process; Android reclaims the idle process and its database connections together. A private receiver refreshes an open UI after delivery.
- The Flutter startup screen paints before opening services. Initialization failures show a Retry button rather than leaving the native splash visible.

## Permissions

| Permission | Why | Requested at runtime |
|---|---|---|
| `MANAGE_EXTERNAL_STORAGE` | Read the model (Android 11+) | Via settings |
| `WRITE_EXTERNAL_STORAGE` (≤ API 29) | Read the model on Android 6–10 | Yes |
| `POST_NOTIFICATIONS` | Reminder notifications | Yes (via plugin) |
| `SCHEDULE_EXACT_ALARM` | Exact reminders | Yes (via plugin) |
| `RECEIVE_BOOT_COMPLETED` | Re-arm reminders after reboot | No |
| `RECORD_AUDIO` | Reserved for speech | **Not requested yet** |

No `INTERNET` in the main manifest. `android/app/src/debug/AndroidManifest.xml` (generated by Flutter) adds it for
debug and profile builds so hot reload works. Release builds have no network permission.

`MANAGE_EXTERNAL_STORAGE` is intended for side-loading. Google Play only allows it with an approved declaration.

## Activity routing

`main.dart` reads `PlatformDispatcher.instance.defaultRouteName`. When it is `/voice`, the app shows only the chat in a
bottom panel (85% of the available height, resizing above the keyboard). Widget startup bypasses the
full-screen profile questionnaire and opens this chat directly. Otherwise it shows the normal app startup
and home screen.
