import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';

import 'data/db.dart';
import 'data/repos.dart';
import 'assistant/engine.dart';
import 'assistant/session.dart';
import 'services/app_services.dart';
import 'services/proactive.dart';
import 'services/reminder_scheduler.dart';
import 'ui/reminder_settings.dart';
import 'package:path/path.dart' as p;

import 'services/model_status.dart';
import 'services/native_bridge.dart';
import 'theme/app_colors.dart';
import 'theme/app_theme.dart';
import 'ui/chat_view.dart';
import 'ui/app_shell.dart';
import 'ui/chat_sidebar.dart';
import 'ui/tasks_page.dart';
import 'ui/memories_page.dart';
import 'ui/model_status_view.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The widget's Talk button launches VoiceSessionActivity with initial route /voice.
  final voice = PlatformDispatcher.instance.defaultRouteName == '/voice';
  runApp(MaterialApp(
    title: 'Corenyth',
    debugShowCheckedModeBanner: false,
    theme: AppTheme.dark,
    darkTheme: AppTheme.dark,
    themeMode: ThemeMode.dark,
    home: ServiceStartup(voice: voice),
  ));
}

/// Paint before initialization; startup failures must not strand the native splash.
class ServiceStartup extends StatefulWidget {
  final bool voice;
  final Future<AppServices> Function() open;
  const ServiceStartup(
      {this.voice = false, this.open = AppServices.open, super.key});

  @override
  State<ServiceStartup> createState() => _ServiceStartupState();
}

class _ServiceStartupState extends State<ServiceStartup> {
  late Future<AppServices> _services;

  @override
  void initState() {
    super.initState();
    _start();
  }

  void _start() {
    _services = widget.open();
    listenProactive((args) async => (await _services).runProactive(args));
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<AppServices>(
        future: _services,
        builder: (context, snapshot) {
          if (snapshot.hasData)
            return AppStart(snapshot.data!, voice: widget.voice);
          return Scaffold(
            body: Center(
              child: snapshot.connectionState == ConnectionState.done &&
                      snapshot.hasError
                  ? Column(mainAxisSize: MainAxisSize.min, children: [
                      const Text(
                          'Could not open Corenyth. Your saved data is kept.'),
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: () => setState(_start),
                        child: const Text('Retry'),
                      ),
                    ])
                  : const Column(mainAxisSize: MainAxisSize.min, children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 16),
                      Text('Opening Corenyth…'),
                    ]),
            ),
          );
        },
      );
}

/// Headless entrypoint ProactiveReceiver (Proactive.kt) starts when an alarm,
/// notification action, boot or time change arrives and no app engine is
/// alive. Delivery only: no UI, no model, no permission prompts.
@pragma('vm:entry-point')
Future<void> proactiveMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  final services = AppServices(await openAppDb(), AlarmReminderScheduler(), '');
  listenProactive(services.runProactive);
  await proactiveChannel.invokeMethod('ready');
}

class AppStart extends StatefulWidget {
  final AppServices services;
  final bool voice;
  const AppStart(this.services, {this.voice = false, super.key});

  @override
  State<AppStart> createState() => _AppStartState();
}

class _AppStartState extends State<AppStart> {
  late Future<UserProfile?> _profile = widget.services.profile.get();
  UserProfile? _readyProfile;
  bool _finishedLoading = false;

  Future<void> _save(UserProfile profile) async {
    await widget.services.profile.save(profile);
    if (mounted) setState(() => _readyProfile = profile);
  }

  @override
  Widget build(BuildContext context) {
    if (_readyProfile != null)
      return _assistantHome(widget.services, widget.voice);
    return FutureBuilder<UserProfile?>(
      future: _profile,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
              body: Center(child: CircularProgressIndicator()));
        }
        if (snapshot.hasError) {
          return const Scaffold(
              body: Center(child: Text('Could not load your profile.')));
        }
        if (!_finishedLoading) {
          _finishedLoading = true;
          _readyProfile = snapshot.data;
        }
        if (snapshot.data == null) {
          return WelcomeQuestionnaire(onSave: _save);
        }
        return _assistantHome(widget.services, widget.voice);
      },
    );
  }
}

Widget _assistantHome(AppServices services, bool voice) => voice
    ? Scaffold(
        backgroundColor: AppColors.transparent,
        body: Align(
          alignment: Alignment.bottomCenter,
          child: FractionallySizedBox(
            heightFactor: 0.55,
            child: Material(
              elevation: 8,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(24)),
              clipBehavior: Clip.antiAlias,
              child: ChatPage(services, closeOnEnd: true),
            ),
          ),
        ),
      )
    : AssistantHome(services);

class AssistantHome extends StatefulWidget {
  final AppServices services;
  const AssistantHome(this.services, {super.key});
  @override
  State<AssistantHome> createState() => _AssistantHomeState();
}

class _AssistantHomeState extends State<AssistantHome>
    with WidgetsBindingObserver {
  List<ChatSummary> _chats = [];
  String? _selected;
  String _name = '';
  String? _error;
  bool _loading = true;
  bool _busy = false; // switching/deleting chats
  bool _chatBusy = false; // the open chat is sending
  int _refresh = 0;
  int _destination = 0;
  int? _focusedTaskId;
  int _taskFocusRevision = 0;
  // A fresh key (so a fresh ChatPage state) per selected chat: no stale log,
  // stream or session can leak from the previous chat.
  var _chat = GlobalKey<_ChatPageState>();
  final _drafts = <String, String>{};

  void _setSelected(String? id) {
    if (id == _selected) return;
    _selected = id;
    _chat = GlobalKey<_ChatPageState>();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    notificationTaps.addListener(_openTasks);
    chatTaps.addListener(_openChat);
    widget.services.proactiveChanged.addListener(_proactive);
    _openTasks();
    _openChat();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    notificationTaps.removeListener(_openTasks);
    chatTaps.removeListener(_openChat);
    widget.services.proactiveChanged.removeListener(_proactive);
    super.dispose();
  }

  /// Alarms delivered while the app was away (or by its background engine)
  /// are caught up, then shown ([_proactive] follows the bump).
  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) widget.services.resumed();
  }

  /// New check-ins: reload the list and the open chat (never mid-reply).
  void _proactive() {
    if (!mounted) return;
    setState(() => _refresh++);
    _load();
    _chat.currentState?.refresh();
  }

  /// A tapped check-in / review notification opens its chat.
  void _openChat() {
    final id = chatTaps.value;
    if (id == null) return;
    chatTaps.value = null;
    if (!mounted) return;
    _openWhenIdle(id);
  }

  Future<void> _openWhenIdle(String id) async {
    for (var i = 0; i < 50 && (_busy || _chatBusy || _loading); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (!mounted) return;
    if (id == ConversationRepo.mainChatId) {
      await widget.services.conversations.ensureMainChat();
    }
    await _switch(id);
  }

  /// A tapped reminder notification opens Tasks (its done/postpone controls).
  void _openTasks() {
    final taskId = notificationTaps.value;
    if (taskId == null) return;
    notificationTaps.value = null;
    if (mounted)
      setState(() {
        _destination = 1;
        _refresh++;
        _focusedTaskId = taskId;
        _taskFocusRevision++;
      });
  }

  Future<void>? _loadOp;
  bool _loadAgain = false;

  /// Serialized: a call during a running load re-runs it once afterwards, so
  /// overlapping refreshes never create extra chats or apply stale results.
  Future<void> _load() {
    if (_loadOp != null) {
      _loadAgain = true;
      return _loadOp!;
    }
    return _loadOp = () async {
      try {
        do {
          _loadAgain = false;
          await _loadOnce();
        } while (_loadAgain && mounted);
      } finally {
        _loadOp = null;
      }
    }();
  }

  Future<void> _loadOnce() async {
    final want = _selected;
    try {
      final c = widget.services.conversations;
      // The stable main chat (check-ins land there) always exists and is the
      // default; deleting it clears its history and it comes back empty.
      await c.ensureMainChat();
      final chats = await c.listChats();
      final profile = await widget.services.profile.get();
      var selected = want;
      if (selected == null || !chats.any((chat) => chat.id == selected)) {
        selected = ConversationRepo.mainChatId;
      }
      if (!mounted) return;
      setState(() {
        _chats = chats;
        // A switch that happened meanwhile wins over this load's choice.
        if (_selected == want) _setSelected(selected);
        _name = profile?.name ?? '';
        _error = null;
        _loading = false;
      });
    } catch (_) {
      if (mounted)
        setState(() {
          _error = 'Could not load chats.';
          _loading = false;
        });
    }
  }

  Future<void> _switch(String? id) async {
    if (_busy || _chatBusy || _loading) return;
    if (id != null && id == _selected) {
      setState(() => _destination = 0); // already open: just show it
      return;
    }
    setState(() => _busy = true);
    try {
      await _loadOp; // never race a load that may itself create a chat
      final old = _selected;
      if (old != null) _drafts[old] = _chat.currentState?.input.text ?? '';
      await _chat.currentState?.shutdown();
      final next = id ?? await widget.services.conversations.createChat();
      if (!mounted) return;
      setState(() {
        _setSelected(next);
        _destination = 0;
      });
      await _load();
    } catch (_) {
      if (mounted)
        setState(() => _error = 'Could not open that chat. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(ChatSummary chat) async {
    if (_busy || _chatBusy) return;
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('Delete chat?'),
              content: Text(
                  'Delete “${chat.title.trim().isEmpty ? 'New chat' : chat.title}” and its messages? Your tasks and memories are kept.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Cancel')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Delete')),
              ],
            ));
    if (confirmed != true || !mounted || _busy || _chatBusy) return;
    setState(() => _busy = true);
    try {
      await _loadOp;
      if (_selected == chat.id) await _chat.currentState?.shutdown();
      await widget.services.conversations.deleteChat(chat.id);
      _drafts.remove(chat.id);
      if (_selected == chat.id) _setSelected(null);
      await _load();
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not delete chat. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _profile() async {
    if (await showProfileEditor(context, widget.services.profile) && mounted) {
      setState(() => _refresh++);
      await _load();
    }
  }

  void _settings() => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => SafeArea(
            child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(children: [
                  ModelSetupCard(widget.services),
                  const SizedBox(height: 24),
                  ReminderSettings(widget.services.preferences,
                      onTest: widget.services.testNotification),
                ]))),
      );

  @override
  Widget build(BuildContext context) => AppShell(
        onProfile: _profile,
        onSettings: _settings,
        selectedDestination: _destination,
        onDestinationChanged: (index) {
          setState(() {
            _destination = index;
            _refresh++;
          });
          _load();
        },
        sidebar: Builder(builder: (context) {
          void dismiss() {
            if (Scaffold.maybeOf(context)?.isDrawerOpen == true)
              Navigator.pop(context);
          }

          return ChatSidebar(
              chats: _chats,
              selectedId: _selected,
              busy: _busy || _chatBusy || _loading,
              error: _error,
              onRetry: _load,
              onNewChat: () {
                dismiss();
                _switch(null);
              },
              onSelect: (id) {
                dismiss();
                _switch(id);
              },
              onDelete: _delete);
        }),
        pages: [
          Column(children: [
            ModelSetupCard(widget.services, compact: true),
            ValueListenableBuilder<String?>(
                valueListenable: widget.services.reminderIssue,
                builder: (_, issue, __) => issue == null
                    ? const SizedBox.shrink()
                    : Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 4),
                        child: Text(issue,
                            style: TextStyle(color: AppColors.error)))),
            Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _selected == null
                        ? Center(
                            child: TextButton(
                                onPressed: _load,
                                child: const Text('Retry loading chats')))
                        : ChatPage(widget.services,
                            key: _chat,
                            conversationId: _selected,
                            name: _name,
                            draft: _drafts[_selected] ?? '',
                            onBusyChanged: (busy) {
                            widget.services.chatBusy.value = busy;
                            if (mounted) setState(() => _chatBusy = busy);
                          }, onChanged: () {
                            if (mounted) {
                              setState(() => _refresh++);
                              _load();
                            }
                          })),
          ]),
          TasksPage(widget.services.tasks,
              key: ValueKey('task-focus-$_taskFocusRevision'),
              focusTaskId: _focusedTaskId,
              refreshToken: _refresh,
              reminders: widget.services.reminders),
          MemoriesPage(
              memory: widget.services.memory,
              profile: widget.services.profile,
              refreshToken: _refresh),
        ],
      );
}

class WelcomeQuestionnaire extends StatefulWidget {
  final Future<void> Function(UserProfile profile) onSave;
  const WelcomeQuestionnaire({required this.onSave, super.key});

  @override
  State<WelcomeQuestionnaire> createState() => _WelcomeQuestionnaireState();
}

class _WelcomeQuestionnaireState extends State<WelcomeQuestionnaire> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _occupation = TextEditingController();
  String _tone = 'cheerful';
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _occupation.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    await widget.onSave(UserProfile(
      name: _name.text,
      occupation: _occupation.text,
      tone: _tone,
    ));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Let’s get to know you')),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Form(
                  key: _form,
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text(
                            'A few quick details help me feel more like your assistant.',
                            style: TextStyle(fontSize: 17)),
                        const SizedBox(height: 20),
                        TextFormField(
                          controller: _name,
                          textCapitalization: TextCapitalization.words,
                          decoration: const InputDecoration(
                              labelText: 'What should I call you?',
                              border: OutlineInputBorder()),
                          validator: (value) =>
                              value == null || value.trim().isEmpty
                                  ? 'Please enter your name.'
                                  : null,
                        ),
                        const SizedBox(height: 14),
                        TextField(
                          controller: _occupation,
                          textCapitalization: TextCapitalization.sentences,
                          decoration: const InputDecoration(
                              labelText: 'What do you do? (optional)',
                              border: OutlineInputBorder()),
                        ),
                        const SizedBox(height: 14),
                        DropdownButtonFormField<String>(
                          initialValue: _tone,
                          decoration: const InputDecoration(
                              labelText: 'Choose my tone',
                              border: OutlineInputBorder()),
                          items: const [
                            DropdownMenuItem(
                                value: 'mature', child: Text('Mature')),
                            DropdownMenuItem(
                                value: 'cheerful', child: Text('Cheerful')),
                            DropdownMenuItem(
                                value: 'playful', child: Text('Playful')),
                            DropdownMenuItem(
                                value: 'calm', child: Text('Calm')),
                            DropdownMenuItem(
                                value: 'professional',
                                child: Text('Professional')),
                          ],
                          onChanged: (value) =>
                              setState(() => _tone = value ?? 'cheerful'),
                        ),
                        const SizedBox(height: 22),
                        FilledButton(
                          onPressed: _saving ? null : _submit,
                          child: Text(_saving ? 'Saving…' : 'Save & start'),
                        ),
                        const SizedBox(height: 10),
                        const Text(
                            'Your answers are saved on this device and can shape the assistant’s replies.',
                            textAlign: TextAlign.center),
                      ]),
                ),
              ),
            ),
          ),
        ),
      );
}

class ChatPage extends StatefulWidget {
  final AppServices services;
  final bool closeOnEnd;
  final String name;
  final String? conversationId;
  final String draft;
  final ValueChanged<bool>? onBusyChanged;
  final VoidCallback? onChanged;
  const ChatPage(this.services,
      {this.closeOnEnd = false,
      this.name = '',
      this.conversationId,
      this.draft = '',
      this.onBusyChanged,
      this.onChanged,
      super.key});
  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  AssistantSession? session;
  final log = <Message>[];
  final input = TextEditingController();
  final _scroll = ScrollController();
  StreamSubscription<SessionState>? _subscription;
  Future<void>? _opening;
  String? _conversationId;
  bool _sending = false;
  bool _loading = true;
  bool _stopping = false;
  String? _error;
  String? _streaming;
  String? _fallback;
  var state = SessionState.idle;

  @override
  void initState() {
    super.initState();
    input.text = widget.draft;
    widget.services.modelLoad.addListener(_onModelLoad);
    _loadConversation();
  }

  Future<void> _loadConversation() async {
    setState(() {
      _loading = true;
      _error = null;
      _fallback = null;
      log.clear();
    });
    try {
      await shutdown();
      final id = widget.conversationId ??
          await widget.services.conversations.createChat();
      final messages = await widget.services.conversations.messages(id);
      if (!mounted) return;
      _conversationId = id;
      setState(() {
        log.addAll(messages);
        _loading = false;
      });
      await _open();
      _scrollToEnd();
    } catch (_) {
      if (mounted)
        setState(() {
          _loading = false;
          _error = 'Could not load this conversation. Try again.';
        });
    }
  }

  /// Re-reads the stored messages (check-ins written in the background)
  /// without touching the session; skipped while a reply is running.
  Future<void> refresh() async {
    final id = _conversationId;
    if (id == null || _sending || _loading) return;
    try {
      final messages = await widget.services.conversations.messages(id);
      if (!mounted || _sending || _loading || id != _conversationId) return;
      setState(() => log
        ..clear()
        ..addAll(messages));
      _scrollToEnd();
    } catch (_) {} // the shown log stays; the next refresh retries
  }

  Future<void> _onModelLoad() async {
    final current = session;
    if (current == null ||
        widget.services.modelLoad.value != ModelLoad.loaded ||
        current.engine is LlamaChannelEngine &&
            current.engineInUse == current.engine.name ||
        state != SessionState.listening ||
        _sending) return;
    await shutdown();
    if (mounted) await _open();
  }

  Future<void> _open() {
    final pending = _opening;
    if (pending != null) return pending;
    return _opening = _startSession().whenComplete(() => _opening = null);
  }

  Future<void> _startSession() async {
    await _subscription?.cancel();
    final current = widget.services
        .newSession(conversationId: _conversationId, onIdleTimeout: _end);
    session = current;
    _subscription = current.state.stream.listen((value) {
      if (mounted) setState(() => state = value);
    });
    try {
      await current.start();
      if (!mounted) {
        await current.close();
        return;
      }
      setState(() {
        state = current.current;
        _error = null;
      });
    } catch (_) {
      if (mounted)
        setState(() => _error = 'Could not start the assistant. Try again.');
    }
  }

  Future<void> _send() async {
    final text = input.text.trim();
    if (text.isEmpty || _sending || _loading) return;
    setState(() {
      _sending = true;
      _error = null;
      _fallback = null;
      _streaming = null;
    });
    widget.onBusyChanged?.call(true);
    try {
      if (state == SessionState.idle) await _open();
      final current = session;
      if (!mounted ||
          current == null ||
          current.current != SessionState.listening) return;
      input.clear();
      setState(() => log.add(Message('user', text)));
      _scrollToEnd();
      final reply = await current.handle(text, onText: (text) {
        if (mounted) {
          setState(() => _streaming = text);
          _scrollToEnd();
        }
      });
      if (mounted) {
        // '' = cancelled before any reply: drop the streamed draft, add nothing.
        setState(() {
          if (reply.isNotEmpty) log.add(Message('assistant', reply));
          _streaming = null;
          _fallback = current.lastFallbackReason;
          if (reply.isEmpty && _stopping) _error = 'Response stopped.';
        });
        _scrollToEnd();
        widget.onChanged?.call();
      }
    } catch (_) {
      if (mounted)
        setState(() {
          _streaming = null;
          _error = _stopping
              ? 'Response stopped.'
              : 'Could not finish that message. Check your tasks before retrying.';
        });
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
          _stopping = false;
        });
        widget.onBusyChanged?.call(false);
      }
    }
  }

  Future<void> _stop() async {
    if (_stopping) return;
    setState(() => _stopping = true);
    try {
      await session?.cancel();
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not stop the response.');
    }
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients)
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 160), curve: Curves.easeOut);
    });
  }

  Future<void> shutdown() async {
    await _opening;
    await session?.close();
  }

  Future<void> _end() async {
    await shutdown();
    if (widget.closeOnEnd) {
      await NativeBridge.closeActivity();
    } else if (mounted) setState(() => state = SessionState.idle);
  }

  @override
  void dispose() {
    widget.services.modelLoad.removeListener(_onModelLoad);
    _subscription?.cancel();
    unawaited(shutdown());
    input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(children: [
        if (widget.closeOnEnd)
          Row(children: [
            Padding(padding: const EdgeInsets.all(12), child: Text(state.name)),
            const Spacer(),
            IconButton(
                tooltip: 'Close chat',
                icon: const Icon(Icons.close),
                onPressed: _end),
          ]),
        if (_error != null)
          Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(children: [
                Expanded(
                    child: Text(_error!,
                        style: TextStyle(color: AppColors.error))),
                if (!_sending)
                  TextButton(
                      onPressed: _loadConversation, child: const Text('Retry')),
              ])),
        if (_fallback != null)
          Padding(
              padding: const EdgeInsets.all(12),
              child: Text('Answered with built-in rules: $_fallback.',
                  style: Theme.of(context).textTheme.bodySmall)),
        Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ChatView(
                    name: widget.name,
                    messages: log,
                    input: input,
                    scroll: _scroll,
                    busy: _sending,
                    ready: state == SessionState.listening ||
                        state == SessionState.idle,
                    streamingText: _streaming,
                    onStop: _stopping ? null : _stop,
                    onSend: _send)),
      ]);
}

/// Step-by-step model install guide, optionally presented as a compact status.
/// Re-checks whenever the app resumes (the user leaves to download/move the file).
class ModelSetupCard extends StatefulWidget {
  final AppServices services;
  final bool compact;
  const ModelSetupCard(this.services, {this.compact = false, super.key});
  @override
  State<ModelSetupCard> createState() => _ModelSetupCardState();
}

class _ModelSetupCardState extends State<ModelSetupCard>
    with WidgetsBindingObserver {
  static const _folder = 'Documents/localmodels';
  ModelState? _state;
  bool _checking = false;
  bool _checkFailed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didHaveMemoryPressure() {
    if (widget.compact) widget.services.releaseModel();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) {
      _check();
      // Retry unconfirmed alarm intents and re-read permissions (compact card = home screen, once).
      if (widget.compact) widget.services.checkReminders();
    }
  }

  Future<void> _check() async {
    if (_checking) return;
    _checking = true;
    try {
      final s = await widget.services.modelState();
      if (!mounted) return;
      setState(() {
        _state = s;
        _checkFailed = false;
      });
      // Preserve the existing automatic model load when the complete file is ready.
      if (s == ModelState.ready &&
          widget.services.modelLoad.value == ModelLoad.idle) _load();
    } catch (_) {
      if (mounted) setState(() => _checkFailed = true);
    } finally {
      _checking = false;
    }
  }

  void _showDetails() => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => SafeArea(
          child: FractionallySizedBox(
              heightFactor: 0.85,
              child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: ModelSetupCard(widget.services)))));

  void _load() {
    final sv = widget.services;
    showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => ModelLoadDialog(sv.modelLoad, onRetry: sv.loadModel));
    sv.loadModel();
  }

  bool _switching = false;

  /// Catalog picker. Disabled while a load/switch runs; a not-installed
  /// choice is saved and its download offered.
  Widget _picker(bool loading) => ValueListenableBuilder<bool>(
      valueListenable: widget.services.chatBusy,
      builder: (context, replying, _) =>
          _pickerBody(loading || replying, replying));

  Widget _pickerBody(bool busy, bool replying) {
    final sv = widget.services;
    final dir = p.dirname(sv.modelPath);
    final selected = sv.selectedModel;
    bool installed(ModelSpec m) =>
        checkModelSpec(dir, m, granted: true) == ModelState.ready;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Model', style: Theme.of(context).textTheme.titleSmall),
      for (final m in modelCatalog)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(m.id == selected.id
              ? Icons.radio_button_checked
              : Icons.radio_button_unchecked),
          selected: m.id == selected.id,
          enabled: !busy && !_switching,
          // The selected row stays tappable until it is the loaded model (e.g. a
          // choice saved before its file was installed).
          onTap: m.id == sv.activeModel?.id &&
                  sv.modelLoad.value == ModelLoad.loaded
              ? null
              : () => _select(m),
          title: Text(m.label),
          subtitle: Text('${m.fileName} · about ${m.approxMiB} MB · '
              '${installed(m) ? 'installed' : 'not installed'}'),
        ),
      if (!installed(selected))
        OutlinedButton(
            onPressed: () => NativeBridge.openUrl(selected.url),
            child: Text('Download ${selected.fileName}')),
      if (replying)
        const Text('Wait for the current reply to finish to switch models.'),
      const Text('The larger model needs more memory and answers more slowly. '
          'Memory use and speed have not been measured on this phone. '
          'If it fails to load, the app returns to the default model.'),
    ]);
  }

  Future<void> _select(ModelSpec m) async {
    setState(() => _switching = true);
    try {
      final ok = await widget.services.selectModel(m);
      if (!mounted) return;
      final installed = checkModelSpec(p.dirname(widget.services.modelPath), m,
              granted: true) ==
          ModelState.ready;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
          content: Text(ok
              ? 'Now using ${m.label}.'
              : !installed
                  ? '${m.label} selected. Put ${m.fileName} in $_folder to use it.'
                  : 'Could not load ${m.label}.')));
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _state;
    if (_checkFailed)
      return Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            const Expanded(child: Text('Could not check the local model.')),
            TextButton(onPressed: _check, child: const Text('Retry'))
          ]));
    if (widget.compact)
      return ListenableBuilder(
          listenable: Listenable.merge(
              [widget.services.modelLoad, widget.services.modelNote]),
          builder: (context, _) => ModelStatusView(
              modelState: s,
              load: widget.services.modelLoad.value,
              onTap: _showDetails,
              selectedLabel: widget.services.selectedModel.label,
              activeLabel: widget.services.activeModel?.label,
              fellBack: widget.services.modelNote.value != null));
    if (s == null) return const SizedBox.shrink();
    final sv = widget.services;
    final want = sv.selectedModel;
    if (s == ModelState.ready)
      return ListenableBuilder(
          listenable: Listenable.merge([sv.modelLoad, sv.modelNote]),
          builder: (context, _) {
            final load = sv.modelLoad.value;
            return Card(
                child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Your local model',
                              style: Theme.of(context).textTheme.headlineSmall),
                          const SizedBox(height: 12),
                          Text('Selected: ${want.label}'),
                          Text(
                              'Active: ${load == ModelLoad.loaded ? sv.activeModel?.label ?? 'local model' : 'built-in rules'}'),
                          if (sv.modelNote.value != null)
                            Text(sv.modelNote.value!,
                                style: const TextStyle(color: AppColors.gold)),
                          const SizedBox(height: 8),
                          Text(switch (load) {
                            ModelLoad.loaded =>
                              'Loaded on this device. No cloud connection required.',
                            ModelLoad.failed =>
                              'Loading failed. The assistant is using built-in rules.',
                            ModelLoad.loading => 'Loading on this device…',
                            ModelLoad.idle =>
                              'The model file is ready to load.',
                          }),
                          if (load == ModelLoad.failed ||
                              load == ModelLoad.idle)
                            Padding(
                                padding: const EdgeInsets.only(top: 16),
                                child: FilledButton(
                                    onPressed: _load,
                                    child: Text(load == ModelLoad.failed
                                        ? 'Retry loading'
                                        : 'Load model'))),
                          const SizedBox(height: 16),
                          _picker(load == ModelLoad.loading),
                        ])));
          });
    Widget step(int n, String text, [Widget? action]) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          CircleAvatar(
              radius: 11,
              child: Text('$n', style: const TextStyle(fontSize: 12))),
          const SizedBox(width: 10),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(text),
                if (action != null) action,
              ])),
        ]));
    return Card(
        margin: EdgeInsets.zero,
        child: Padding(
            padding: const EdgeInsets.all(24),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Set up the local model',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(s == ModelState.incomplete
                  ? 'A file named ${want.fileName} is in $_folder, but it is not ${want.expectedBytes} bytes '
                      '(unfinished copy, or a different file). Replace it with the file from step 2.'
                  : 'Until it is installed the assistant uses simple built-in rules.'),
              step(
                  1,
                  'Allow file access so the app can use $_folder.',
                  s == ModelState.noAccess
                      ? FilledButton(
                          onPressed: NativeBridge.requestStorageAccess,
                          child: const Text('Grant access'))
                      : const Text('Done.',
                          style: TextStyle(color: AppColors.success))),
              step(
                  2,
                  'Download ${want.fileName} (about ${want.approxMiB} MB, use Wi-Fi). Keep the file name exactly.',
                  OutlinedButton(
                      onPressed: () => NativeBridge.openUrl(want.url),
                      child: const Text('Open download page'))),
              step(
                  3,
                  'When it finishes, open the Files app > Downloads, long-press the file, '
                  'choose Move to... and pick Documents > $_folder.'),
              step(
                  4,
                  'Come back here. The app re-checks by itself and loads the model right away.',
                  TextButton(
                      onPressed: _check, child: const Text('Check again'))),
              const SizedBox(height: 16),
              ValueListenableBuilder<ModelLoad>(
                  valueListenable: sv.modelLoad,
                  builder: (context, load, _) =>
                      _picker(load == ModelLoad.loading)),
            ])));
  }
}

/// Popup for the model load: spinner while loading, then success or failure.
class ModelLoadDialog extends StatelessWidget {
  final ValueNotifier<ModelLoad> load;
  final VoidCallback onRetry;
  const ModelLoadDialog(this.load, {required this.onRetry, super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<ModelLoad>(
      valueListenable: load,
      builder: (context, v, _) {
        final busy = v == ModelLoad.idle || v == ModelLoad.loading;
        return PopScope(
            canPop: !busy,
            child: AlertDialog(
              icon: busy
                  ? const SizedBox(
                      width: 40,
                      height: 40,
                      child: CircularProgressIndicator(strokeWidth: 3))
                  : v == ModelLoad.loaded
                      ? const Icon(Icons.check_circle,
                          color: AppColors.success, size: 40)
                      : const Icon(Icons.error_outline,
                          color: AppColors.error, size: 40),
              title: Text(busy
                  ? 'Loading model...'
                  : v == ModelLoad.loaded
                      ? 'Model loaded successfully'
                      : 'Could not load the model'),
              content: Text(busy
                  ? 'This can take a few seconds. Please wait.'
                  : v == ModelLoad.loaded
                      ? 'The assistant is now using the local model.'
                      : 'The assistant keeps using its built-in rules. '
                          'Check that the model file in Documents/localmodels is the complete file.'),
              actions: busy
                  ? null
                  : [
                      if (v == ModelLoad.failed)
                        TextButton(
                            onPressed: onRetry, child: const Text('Retry')),
                      TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('OK')),
                    ],
            ));
      });
}
