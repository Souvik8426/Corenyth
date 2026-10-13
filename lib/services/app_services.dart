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

  AppServices._(this.db, this.scheduler, this.modelPath)
      : tasks = TaskRepo(db),
        reminders = ReminderRepo(db),
        memory = MemoryRepo(db),
        profile = ProfileRepo(db),
        conversations = ConversationRepo(db);

  static Future<AppServices> open() async {
    final db = await openAppDb();
    final sched = AlarmReminderScheduler();
    await sched.init();
    final models = await NativeBridge
        .modelsDir(); // creates Documents/localmodels on every boot
    final s = AppServices._(db, sched, p.join(models.path, modelFileName));
    await sched.rescheduleAll(s.reminders);
    return s;
  }

  /// Native load progress for the popup. The model is process-wide, so sessions
  /// started after it is loaded reuse it (LlamaBridge treats the same path as a no-op).
  final modelLoad = ValueNotifier(ModelLoad.idle);

  /// Loads the model now instead of waiting for the next session. No-op while loading.
  Future<void> loadModel() async {
    if (modelLoad.value == ModelLoad.loading) return;
    modelLoad.value = ModelLoad.loading;
    modelLoad.value = await LlamaChannelEngine(modelPath).load()
        ? ModelLoad.loaded
        : ModelLoad.failed;
  }

  /// Re-checks storage access + the model file (also re-creates the folder if it vanished).
  Future<ModelState> modelState() async {
    final d = await NativeBridge.modelsDir();
    return checkModel(p.join(d.path, modelFileName), granted: d.granted);
  }

  /// Uses llama.cpp only if the complete model file is installed; otherwise rules.
  LlmEngine _engine() =>
      checkModel(modelPath, granted: true) == ModelState.ready
          ? LlamaChannelEngine(modelPath)
          : RuleEngine();

  ToolExecutor executor() => ToolExecutor(tasks, reminders, memory, scheduler,
      onTasksChanged: NativeBridge.refreshWidget);

  AssistantSession newSession({void Function()? onIdleTimeout}) =>
      AssistantSession(
        engine: _engine(),
        tools: executor(),
        memory: memory,
        profile: profile,
        taskRepo: tasks,
        conversations: conversations,
        onIdleTimeout: onIdleTimeout,
      );
}
