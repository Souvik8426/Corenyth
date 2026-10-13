import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';

import 'data/repos.dart';
import 'assistant/engine.dart';
import 'assistant/session.dart';
import 'services/app_services.dart';
import 'services/model_status.dart';
import 'services/native_bridge.dart';
import 'theme/app_colors.dart';
import 'theme/app_theme.dart';
import 'ui/chat_view.dart';
import 'ui/model_status_view.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final services = await AppServices.open();
  // The widget's Talk button launches VoiceSessionActivity with initial route /voice.
  final voice = PlatformDispatcher.instance.defaultRouteName == '/voice';
  runApp(MaterialApp(
    title: 'Corenyth',
    debugShowCheckedModeBanner: false,
    theme: AppTheme.dark,
    darkTheme: AppTheme.dark,
    themeMode: ThemeMode.dark,
    home: AppStart(services, voice: voice),
  ));
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
    : DefaultTabController(
        length: 3,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Assistant'),
            bottom: const TabBar(tabs: [
              Tab(text: 'Chat'),
              Tab(text: 'Tasks'),
              Tab(text: 'Memories'),
            ]),
          ),
          body: TabBarView(children: [
            Column(children: [
              Flexible(
                  child:
                      SingleChildScrollView(child: ModelSetupCard(services))),
              Expanded(child: ChatPage(services)),
            ]),
            ListPage(() async => (await services.tasks.list(includeDone: true))
                .map((t) => t.toString())
                .toList()),
            MemoryPage(services),
          ]),
        ),
      );

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
  const ChatPage(this.services,
      {this.closeOnEnd = false, this.name = '', super.key});
  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  late AssistantSession session;
  final log = <Message>[];
  final input = TextEditingController();
  final _scroll = ScrollController();
  StreamSubscription<SessionState>? _subscription;
  Future<void>? _opening;
  bool _sending = false;
  String? _error;
  var state = SessionState.idle;

  @override
  void initState() {
    super.initState();
    widget.services.modelLoad.addListener(_onModelLoad);
    _open();
  }

  /// The model finished loading while this session was running on rules: restart
  /// onto it. Mid-turn the restart is skipped and the next session picks it up.
  Future<void> _onModelLoad() async {
    final onModel = session.engine is LlamaChannelEngine &&
        session.engineInUse == session.engine.name;
    if (widget.services.modelLoad.value != ModelLoad.loaded ||
        onModel ||
        state != SessionState.listening ||
        _sending) {
      return;
    }
    await session.close();
    if (!mounted) return;
    _open();
  }

  Future<void> _open() {
    final pending = _opening;
    if (pending != null) return pending;
    final future = _startSession();
    _opening = future;
    return future.whenComplete(() => _opening = null);
  }

  Future<void> _startSession() async {
    await _subscription?.cancel();
    session = widget.services.newSession(onIdleTimeout: _end);
    _subscription = session.state.stream.listen((s) {
      if (mounted) setState(() => state = s);
    });
    try {
      await session.start();
      if (!mounted) {
        await session.close();
        return;
      }
      setState(() {
        state = session.current;
        _error = null;
      });
    } catch (_) {
      if (mounted)
        setState(() => _error = 'Could not start the assistant. Try again.');
    }
  }

  Future<void> _send() async {
    final text = input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      if (state == SessionState.idle) await _open();
      if (!mounted || session.current != SessionState.listening) return;
      input.clear();
      setState(() => log.add(Message('user', text)));
      _scrollToEnd();
      final reply = await session.handle(text);
      if (mounted) {
        setState(() => log.add(Message('assistant', reply)));
        _scrollToEnd();
      }
    } catch (_) {
      if (mounted)
        setState(() {
          input.text = text;
          _error =
              'Could not finish that message. Check your tasks before retrying.';
        });
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 240), curve: Curves.easeOut);
      }
    });
  }

  Future<void> _end() async {
    await session.close();
    if (widget.closeOnEnd) {
      await NativeBridge.closeActivity();
    } else if (mounted) {
      setState(() => state = SessionState.idle);
    }
  }

  @override
  void dispose() {
    widget.services.modelLoad.removeListener(_onModelLoad);
    _subscription?.cancel();
    if (_opening == null) session.close();
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
                onPressed: _sending ? null : _end),
          ]),
        if (_error != null)
          Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(children: [
                Expanded(
                    child: Text(_error!,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall!
                            .copyWith(color: AppColors.error))),
                if (!_sending)
                  TextButton(
                      onPressed: () async {
                        await session.close();
                        if (mounted) await _open();
                      },
                      child: const Text('Retry'))
              ])),
        Expanded(
            child: ChatView(
                name: widget.name,
                messages: log,
                input: input,
                scroll: _scroll,
                busy: _sending,
                ready: state == SessionState.listening ||
                    state == SessionState.idle,
                onSend: _send)),
      ]);
}

class ListPage extends StatelessWidget {
  final Future<List<String>> Function() load;
  const ListPage(this.load, {super.key});
  @override
  Widget build(BuildContext context) => FutureBuilder<List<String>>(
      future: load(),
      builder: (_, s) => ListView(children: [
            for (final l in s.data ?? const <String>[]) ListTile(title: Text(l))
          ]));
}

class MemoryPage extends StatefulWidget {
  final AppServices services;
  const MemoryPage(this.services, {super.key});

  @override
  State<MemoryPage> createState() => _MemoryPageState();
}

class _MemoryPageState extends State<MemoryPage> {
  late Future<String> _context;

  @override
  void initState() {
    super.initState();
    _context = _loadContext();
  }

  Future<String> _loadContext() async {
    final profile = await widget.services.profile.get() ?? const UserProfile();
    final memories = await widget.services.memory.important();
    return buildPersonalContext(
        profile, memories.map((m) => m.content).toList());
  }

  void _reload() => setState(() => _context = _loadContext());

  @override
  Widget build(BuildContext context) => Column(children: [
        Align(
          alignment: Alignment.centerRight,
          child: IconButton(
            tooltip: 'Refresh memories',
            onPressed: _reload,
            icon: const Icon(Icons.refresh),
          ),
        ),
        Expanded(
          child: FutureBuilder<String>(
            future: _context,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return const Center(child: Text('Could not load memories.'));
              }
              return ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                children: [
                  Text('Your assistant’s context',
                      style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 10),
                  Text(snapshot.data!.isEmpty
                      ? 'I haven’t learned any personal details yet.'
                      : snapshot.data!),
                  const SizedBox(height: 14),
                  Text(
                      'Saved on this device • Mem0 is not connected in this version.',
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              );
            },
          ),
        ),
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
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) _check();
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
      return ValueListenableBuilder<ModelLoad>(
          valueListenable: widget.services.modelLoad,
          builder: (context, load, child) =>
              ModelStatusView(modelState: s, load: load, onTap: _showDetails));
    if (s == null) return const SizedBox.shrink();
    if (s == ModelState.ready)
      return ValueListenableBuilder<ModelLoad>(
          valueListenable: widget.services.modelLoad,
          builder: (context, load, _) => Card(
              child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Your local model',
                            style: Theme.of(context).textTheme.headlineSmall),
                        const SizedBox(height: 12),
                        const Text(modelFileName),
                        const SizedBox(height: 8),
                        Text(switch (load) {
                          ModelLoad.loaded =>
                            'Loaded on this device. No cloud connection required.',
                          ModelLoad.failed =>
                            'Loading failed. The assistant is using built-in rules.',
                          ModelLoad.loading => 'Loading on this device…',
                          ModelLoad.idle => 'The model file is ready to load.',
                        }),
                        if (load == ModelLoad.failed || load == ModelLoad.idle)
                          Padding(
                              padding: const EdgeInsets.only(top: 16),
                              child: FilledButton(
                                  onPressed: _load,
                                  child: Text(load == ModelLoad.failed
                                      ? 'Retry loading'
                                      : 'Load model'))),
                      ]))));
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
                  ? 'A file named $modelFileName is in $_folder, but it is not $modelBytes bytes '
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
                  'Download $modelFileName (about 365 MB, use Wi-Fi). Keep the file name exactly.',
                  OutlinedButton(
                      onPressed: () => NativeBridge.openUrl(modelUrl),
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
                  ? const CircularProgressIndicator()
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
                          'Check that $modelFileName in Documents/localmodels is the complete file.'),
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
