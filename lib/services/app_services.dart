import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../assistant/engine.dart';
import '../assistant/rule_engine.dart';
import '../assistant/session.dart';
import '../assistant/tools.dart';
import '../data/db.dart';
import '../data/repos.dart';
import 'model_status.dart';
import 'native_bridge.dart';
import 'reminder_scheduler.dart';

const modelFileName = 'Qwen3-0.6B-Q4_0.gguf';

/// Composition root: one DB, repos, scheduler. Sessions are created per conversation.
class AppServices {
  final Database db;
  final TaskRepo tasks;
  final ReminderRepo reminders;
  final MemoryRepo memory;
  final ProfileRepo profile;
  final ConversationRepo conversations;
  final ReminderScheduler scheduler;
  final String modelPath;

  /// Public for tests; the app uses [open].
  AppServices(this.db, this.scheduler, this.modelPath)
      : tasks = TaskRepo(db),
        reminders = ReminderRepo(db),
        memory = MemoryRepo(db),
        profile = ProfileRepo(db),
        conversations = ConversationRepo(db);

  static Future<AppServices> open() async {
    final db = await openAppDb();
    final sched = AlarmReminderScheduler();
    String? issue;
    try {
      await sched.init();
    } catch (_) {
      issue = 'Notifications could not be set up; reminders may not fire.';
    }
    final models = await NativeBridge
        .modelsDir(); // creates Documents/localmodels on every boot
    final s = AppServices(db, sched, p.join(models.path, modelFileName));
    try {
      final failed = await sched.rescheduleAll(s.reminders);
      if (failed.isNotEmpty) {
        issue ??= 'Could not schedule reminder${failed.length > 1 ? 's' : ''} '
            '${failed.map((id) => '#$id').join(', ')}; they may not fire.';
      }
    } catch (_) {
      issue ??= 'Reminders could not be restored; they may not fire.';
    }
    s.schedulingIssue = issue;
    return s;
  }

  /// Startup reminder-scheduling problem for the UI to show, or null.
  String? schedulingIssue;

  /// Native load progress for the popup.
  final modelLoad = ValueNotifier(ModelLoad.idle);

  /// Owner of the one native model load/unload. Requests go through per-session
  /// engines (see [newSession]) so a session's cancel only stops its own requests.
  LlamaChannelEngine? _llama;
  Future<bool>? _loading;
  Future<void>? _releasing;

  /// Single load owner: concurrent callers share one native load; a failed
  /// load may be retried. Chat switches never unload. Waits for a running
  /// [releaseModel] so a load is never undone by an older unload.
  ///
  /// Always asks native: residency is process-wide (another activity, or the
  /// OS via memory pressure, may have freed it), and the native `load` is an
  /// idempotent no-op when the same model is resident. When it is believed
  /// loaded the check is silent (no spinner); a needed reload just happens.
  Future<bool> ensureModel() {
    return _loading ??= () async {
      var ok = false;
      try {
        await _releasing;
        if (modelLoad.value != ModelLoad.loaded) {
          modelLoad.value = ModelLoad.loading;
        }
        ok = await (_llama ??= LlamaChannelEngine(modelPath)).load();
      } finally {
        modelLoad.value = ok ? ModelLoad.loaded : ModelLoad.failed;
        _loading = null;
      }
      return ok;
    }();
  }

  /// Loads the model now instead of waiting for the next session.
  Future<void> loadModel() => ensureModel();

  /// Frees the native model (e.g. app shutdown / memory pressure). Status drops
  /// to idle first, so the next inference reloads via [ensureModel].
  Future<void> releaseModel() => _releasing ??= () async {
        try {
          await _loading;
        } catch (_) {}
        modelLoad.value = ModelLoad.idle;
        try {
          await _llama?.unload();
        } finally {
          _releasing = null;
        }
      }();

  /// Re-checks storage access + the model file (also re-creates the folder if it vanished).
  Future<ModelState> modelState() async {
    final d = await NativeBridge.modelsDir();
    return checkModel(p.join(d.path, modelFileName), granted: d.granted);
  }

  /// Uses llama.cpp only if the complete model file is installed; otherwise rules.
  /// A fresh engine per session: request ids (and so cancel) are per instance,
  /// while the native model itself stays shared and loaded via [ensureModel].
  LlmEngine _engine() =>
      checkModel(modelPath, granted: true) == ModelState.ready
          ? LlamaChannelEngine(modelPath)
          : RuleEngine();

  ToolExecutor executor() => ToolExecutor(tasks, reminders, memory, scheduler,
      onTasksChanged: NativeBridge.refreshWidget);

  /// [conversationId] continues an existing chat (see [ConversationRepo.createChat]);
  /// null starts a new one, persisted on its first message.
  AssistantSession newSession(
      {String? conversationId, void Function()? onIdleTimeout}) {
    final engine = _engine();
    return AssistantSession(
      engine: engine,
      tools: executor(),
      memory: memory,
      profile: profile,
      taskRepo: tasks,
      conversations: conversations,
      conversationId: conversationId,
      onIdleTimeout: onIdleTimeout,
      loadEngine: engine is LlamaChannelEngine ? ensureModel : null,
    );
  }
}
