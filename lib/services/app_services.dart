import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../assistant/engine.dart';
import '../assistant/rule_engine.dart';
import '../assistant/session.dart';
import '../assistant/tools.dart';
import '../data/db.dart';
import '../data/repos.dart';
import 'backup/backup_gateway.dart';
import 'backup/backup_service.dart';
import 'model_selection.dart';
import 'model_status.dart';
import 'native_bridge.dart';
import 'proactive.dart';
import 'reminder_scheduler.dart';

/// Reports each save to [saved] (AppServices: nudge cancel, review alarm).
/// The save itself has committed by then, so a failure there never fails it.
class _Preferences extends ReminderPreferencesRepo {
  Future<void> Function(ReminderPreferences before)? saved;
  _Preferences(super.db);

  @override
  Future<void> save(ReminderPreferences value) async {
    final before = await get();
    await super.save(value);
    try {
      await saved?.call(before);
    } catch (_) {} // pending intents are retried at the next sync/startup
  }
}

/// Composition root: one DB, repos, scheduler. Sessions are created per conversation.
class AppServices {
  final Database db;
  final TaskRepo tasks;
  final ReminderRepo reminders;
  final MemoryRepo memory;
  final ProfileRepo profile;
  final ConversationRepo conversations;
  final ReminderPreferencesRepo preferences;
  final PendingRepo pending;
  final ReviewRepo review;
  final OperationJournal operations;
  final ReminderScheduler scheduler;

  /// Backup and restore of the user's saved context. It reads and writes the
  /// database directly, never the model.
  final BackupService backup;

  /// Bumped after each proactive job (alarm, notification action, boot) so
  /// the open chat and lists reload what was written meanwhile.
  final proactiveChanged = ValueNotifier(0);

  /// Model file loads use; [selectModel]/fallback change it only between loads.
  String get modelPath => _path;
  String _path;

  /// Persisted model choice + SHA-256 check; null in tests (no verification,
  /// no fallback, [modelPath] loaded as given).
  ModelSelection? selection;

  /// True while a chat reply is being generated; the model picker waits.
  final chatBusy = ValueNotifier(false);
  final lastAnswerSource = ValueNotifier<String?>(null);

  void recordTurn(AssistantSession session) {
    final d = session.lastDiagnostics;
    lastAnswerSource.value = d['reply'] == 'model' || d['route'] == 'semantic'
        ? 'Local model with app checks'
        : 'Built-in assistant logic';
  }

  /// Why the active model differs from what the user picked, for the UI.
  final modelNote = ValueNotifier<String?>(null);

  /// Machine-readable reason behind the last model fallback/failure, or null:
  /// `crashed_last_run:<id>`, `not_installed:<id>`, `not_allowlisted`,
  /// `sha256_mismatch:<id>`, `load:<engine code>:<id>`. Diagnostics only.
  String? modelFailure;

  /// Model ids, load state and failure code for turn diagnostics; no text.
  Map<String, String> modelDiagnostics() => {
        'build': buildRevision,
        'selected': selectedModel.id,
        'active': activeModel?.id ?? 'none',
        'load': modelLoad.value.name,
        if (modelFailure != null) 'load_failure': modelFailure!,
      };

  /// Public for tests; the app uses [open].
  AppServices(this.db, this.scheduler, String modelPath,
      {BackupFileGateway? backupGateway})
      : _path = modelPath,
        tasks = TaskRepo(db),
        reminders = ReminderRepo(db),
        memory = MemoryRepo(db),
        profile = ProfileRepo(db),
        conversations = ConversationRepo(db),
        preferences = _Preferences(db),
        pending = PendingRepo(db),
        review = ReviewRepo(db),
        operations = OperationJournal(db),
        backup = BackupService(
          db: db,
          reminders: ReminderRepo(db),
          scheduler: scheduler,
          gateway: backupGateway,
        ) {
    // Every task/preference write (chat, Tasks page) syncs linked alarms.
    tasks.onRemindersChanged =
        preferences.onRemindersChanged = () => syncReminders();
    (preferences as _Preferences).saved = _preferencesSaved;
  }

  /// Nudges turned off: pending early alerts go, as follow-ups do when those
  /// are turned off (ReminderPreferencesRepo.save). Either switch re-arms or
  /// cancels the evening review, which follows the follow-up switch.
  Future<void> _preferencesSaved(ReminderPreferences before) async {
    final after = await preferences.get();
    if (before.multiple && !after.multiple) {
      final cancelled = await db.transaction((tx) async {
        for (final t in await tx.query('tasks',
            columns: ['id', 'alert_plan'], where: 'alert_plan IS NOT NULL')) {
          final i = AlertIntentJson.decode(t['alert_plan']);
          if (i == null || i.lead.isEmpty) continue;
          await tx.update('tasks',
              {'alert_plan': (lead: const <int>[], follow: i.follow).encode()},
              where: 'id = ?', whereArgs: [t['id']]);
        }
        return tx.update('reminders', {'enabled': 0, 'sync': 'cancel'},
            where: "kind = 'pre' AND enabled = 1");
      });
      if (cancelled > 0) await syncReminders();
    }
    if (before.quietStart != after.quietStart ||
        before.quietEnd != after.quietEnd) {
      await tasks.refreshPlans();
    }
    await armReview();
  }

  /// App back in the foreground: file what alarms missed, retry intents.
  Future<void> resumed() async {
    try {
      await catchUp();
    } catch (_) {}
    await checkReminders();
    await armReview();
    proactiveChanged.value++;
  }

  /// After a backup was imported: the restored preferences decide when the
  /// evening review rings, the restored tasks need their alarms, and the open
  /// screens have to show what came back.
  Future<void> backupImported() async {
    try {
      await armReview();
    } catch (_) {}
    try {
      await syncReminders();
    } catch (_) {}
    proactiveChanged.value++;
  }

  /// Applies pending alarm intents; ids still out of sync are retried later
  /// (next write, app resume, startup) and shown via [reminderIssue].
  Future<List<int>> syncReminders() async {
    final failed = await scheduler.syncPending(reminders);
    await _status(failed);
    return failed;
  }

  /// The one place [reminderIssue] is decided: unsynced alarms first, then
  /// Android's permission state; null once both are fine (an old failure
  /// never lingers after recovery).
  Future<void> _status(List<int> failed) async {
    String? issue = failed.isEmpty ? null : _failedText(failed);
    if (issue == null) {
      try {
        final d = await scheduler.deliveryIssue();
        if (d != null) issue = 'Reminders are saved, but $d';
      } catch (_) {}
    }
    reminderIssue.value = issue;
  }

  static String _failedText(List<int> ids) =>
      'Could not schedule reminder${ids.length > 1 ? 's' : ''} '
      '${ids.map((id) => '#$id').join(', ')} yet; they may not fire. '
      'I retry when you come back to the app.';

  /// Retries pending alarm intents and re-reads Android's notification and
  /// exact-alarm state (call on resume). Null issue = nothing known wrong,
  /// which is not proof that a notification was delivered.
  Future<void> checkReminders() async {
    try {
      await syncReminders();
    } catch (_) {
      reminderIssue.value =
          'Reminder alarms could not be updated yet; I retry when you come back.';
    }
  }

  /// Schedules one native alarm a few seconds ahead after the permission
  /// checks. Truthful: Android accepting it is not proof it was shown.
  Future<String> testNotification() async {
    try {
      final d = await scheduler.deliveryIssue();
      if (d != null) return 'Not scheduled: $d';
      final at = await scheduler.scheduleTest(const Duration(seconds: 10));
      return 'Test notification scheduled for ${friendlyTime(at, DateTime.now())} '
          '(10 seconds). Android accepted it; check that it actually appears.';
    } catch (_) {
      return "Couldn't schedule a test notification. Check notification and "
          'alarm permissions in Android settings.';
    }
  }

  static Future<AppServices> open() async {
    // Each step is timed and bounded: after an app update the background
    // `:proactive` engine opens the same database at the same moment, and a
    // step that never returns must surface as a Retry, not a frozen screen.
    final clock = Stopwatch()..start();
    Future<T> step<T>(String name, Future<T> Function() f,
        {Duration limit = const Duration(seconds: 15)}) async {
      final t = clock.elapsedMilliseconds;
      try {
        return await f().timeout(limit);
      } finally {
        debugPrint('startup: $name ${clock.elapsedMilliseconds - t} ms');
      }
    }

    final db = await step('database', () => openAppDb());

    final sched = AlarmReminderScheduler();
    String? issue;
    try {
      await step('notifications', sched.init);
    } catch (_) {
      issue = 'Notifications could not be set up; reminders may not fire.';
    }

    // Creates Documents/localmodels on every boot.
    final models = await step('models folder', NativeBridge.modelsDir);

    final sel = await ModelSelection.open();
    final crashed = await sel.crashedAttempt();
    String? note, failure;
    if (crashed != null) failure = 'crashed_last_run:${crashed.id}';
    if (crashed != null && crashed.id != defaultModelId) {
      await sel.writeId(defaultModelId);
      note = '${crashed.label} did not finish loading last time (the phone may '
          'have run out of memory), so the default model is selected again.';
    }
    final want = sel.selected;
    final use = sel.resolveLoadable(models.path) ?? want;
    if (use.id != want.id) {
      note ??= '${want.label} is not installed; using ${use.label}.';
      failure ??= 'not_installed:${want.id}';
    }
    final s = AppServices(db, sched, sel.pathIn(models.path, use))
      ..selection = sel;
    // The backup carries the chosen model id, so it needs the same store.
    s.backup.selection = sel;
    s.modelNote.value = note;
    s.modelFailure = failure;
    debugPrint('model boot: ${s.modelDiagnostics()}');
    try {
      await step('main chat', s.conversations.ensureMainChat);
      await step('recover operations', s.operations.recoverStale);
      // Before re-arming: missed occurrences are filed once, never replayed.
      await step('catch up', () => s.catchUp());
    } catch (_) {}

    try {
      await step('review alarm', () => s.armReview());
    } catch (_) {}
    try {
      final failed = await step('reschedule reminders',
          () => sched.rescheduleAll(s.reminders),
          limit: const Duration(seconds: 20));
      if (failed.isNotEmpty) {
        issue ??= 'Could not schedule reminder${failed.length > 1 ? 's' : ''} '
            '${failed.map((id) => '#$id').join(', ')}; they may not fire.';
      }
    } catch (_) {
      issue ??= 'Reminders could not be restored; they may not fire.';
    }
    if (issue == null) {
      try {
        final d = await sched.deliveryIssue();
        if (d != null) issue = 'Reminders are saved, but $d';
      } catch (_) {}
    }
    s.reminderIssue.value = issue;

    return s;
  }

  /// Current reminder-scheduling problem for the UI, or null. Updated at
  /// startup, after writes and on resume ([checkReminders]).
  final reminderIssue = ValueNotifier<String?>(null);

  /// Native load progress for the popup.
  final modelLoad = ValueNotifier(ModelLoad.idle);

  /// Owner of the one native model load/unload. Requests go through per-session
  /// engines (see [newSession]) so a session's cancel only stops its own requests.
  LlamaChannelEngine? _llama;
  Future<bool>? _loading;
  Future<void>? _switching;
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
        ok = await _loadPath();
        final sel = selection;
        final fallback = p.join(p.dirname(_path), corenythModel.fileName);
        if (!ok &&
            sel != null &&
            _path != fallback &&
            checkModelPath(fallback) == ModelState.ready) {
          final failed = modelByFileName(p.basename(_path));
          _path = fallback;
          await sel.writeId(defaultModelId);
          modelNote.value = '${modelNote.value ?? '${failed?.label ?? 'The '
                  'selected model'} could not be loaded.'} The default model is '
              'selected again.';
          ok = await _loadPath();
        }
      } finally {
        if (ok) {
          modelFailure = null;
          if (_failNote != null && modelNote.value == _failNote) {
            modelNote.value = null;
          }
          _failNote = null;
        }
        modelLoad.value = ok ? ModelLoad.loaded : ModelLoad.failed;
        _loading = null;
        debugPrint('model load: ${modelDiagnostics()}');
      }
      return ok;
    }();
  }

  /// One native load of [_path]: SHA-256 check first (production only), and a
  /// crash marker around the native call. A fresh engine per path, so a switch
  /// never reloads an old cached path.
  /// The note [_loadPath] last showed for a failure, cleared once a load works.
  String? _failNote;

  static bool _readable(String path) {
    try {
      File(path).openSync().closeSync();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _loadPath() async {
    final sel = selection;
    final spec = modelByFileName(p.basename(_path));
    if (sel != null) {
      if (spec == null) {
        modelFailure = 'not_allowlisted';
        return false; // only allowlisted ChatML files
      }
      if (!_readable(_path)) {
        // Before file access is granted the file can be listed but not read;
        // that is not a corrupt download.
        modelFailure = 'unreadable:${spec.id}';
        modelNote.value = _failNote = 'Corenyth cannot read ${spec.fileName} '
            'yet. Allow file access, then come back.';
        return false;
      }
      if (!await sel.verify(spec, _path)) {
        modelFailure = 'sha256_mismatch:${spec.id}';
        modelNote.value = _failNote = '${spec.fileName} does not match the '
            'published file (SHA-256 check failed). Download it again.';
        return false;
      }
      await sel.markAttempt(spec.id);
    }
    final engine = _llama = LlamaChannelEngine(_path);
    try {
      final ok = await engine.load();
      if (!ok) {
        modelFailure =
            'load:${engine.lastLoadError ?? 'unknown'}:${spec?.id ?? 'unlisted'}';
      }
      return ok;
    } finally {
      await sel?.clearAttempt();
    }
  }

  /// Saves [spec] as the chosen model and loads it, between other loads only
  /// (native requests run in order, so a running reply finishes first). On a
  /// failed load [ensureModel] falls back to the default model, then rules.
  /// Returns false when [spec]'s file is not installed (choice still saved).
  Future<bool> selectModel(ModelSpec spec) async {
    final sel = selection;
    if (sel == null) return false;
    while (_switching != null) {
      await _switching;
    }
    final done = Completer<void>();
    _switching = done.future;
    try {
      try {
        await _loading;
      } catch (_) {}
      await sel.writeId(spec.id);
      final path = p.join(p.dirname(_path), spec.fileName);
      if (checkModelPath(path) != ModelState.ready) {
        modelNote.value = null;
        return false;
      }
      modelNote.value = null;
      _path = path;
      modelLoad.value =
          ModelLoad.loading; // busy UI while the old model is replaced
      return await ensureModel() && _path == path;
    } finally {
      _switching = null;
      done.complete();
    }
  }

  /// Model the user picked (default when unset).
  ModelSpec get selectedModel => selection?.selected ?? corenythModel;

  /// Catalog model at [modelPath], or null (tests' arbitrary paths).
  ModelSpec? get activeModel => modelByFileName(p.basename(_path));

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
    final sel = selection;
    // Pick up a newly installed file while nothing is loaded or switching.
    if (sel != null &&
        _switching == null &&
        _loading == null &&
        modelLoad.value != ModelLoad.loaded) {
      final use = sel.resolveLoadable(d.path);
      if (use != null) _path = sel.pathIn(d.path, use);
    }
    return checkModelPath(p.join(d.path, p.basename(_path)),
        granted: d.granted);
  }

  /// Uses llama.cpp only if the complete model file is installed; otherwise rules.
  /// A fresh engine per session: request ids (and so cancel) are per instance,
  /// while the native model itself stays shared and loaded via [ensureModel].
  LlmEngine _engine() => checkModelPath(modelPath) == ModelState.ready
      ? LlamaChannelEngine(modelPath)
      : RuleEngine();

  ToolExecutor executor() => ToolExecutor(tasks, reminders, memory, scheduler,
      onTasksChanged: NativeBridge.refreshWidget, preferences: preferences);

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
      pending: pending,
      review: review,
      modelDiagnostics: modelDiagnostics,
      operations: operations,
    );
  }
}
