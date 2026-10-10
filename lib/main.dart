import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';

import 'assistant/engine.dart';
import 'assistant/session.dart';
import 'services/app_services.dart';
import 'services/model_status.dart';
import 'services/native_bridge.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final services = await AppServices.open();
  // The widget's Talk button launches VoiceSessionActivity with initial route /voice.
  final voice = PlatformDispatcher.instance.defaultRouteName == '/voice';
  runApp(MaterialApp(
    title: 'Assistant',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
    home: voice
        ? Scaffold(
            backgroundColor: Colors.transparent,
            body: Align(
              alignment: Alignment.bottomCenter,
              child: FractionallySizedBox(
                  heightFactor: 0.55,
                  child: Material(
                      elevation: 8,
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                      clipBehavior: Clip.antiAlias,
                      child: ChatPage(services, closeOnEnd: true))),
            ))
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
                  Flexible(child: SingleChildScrollView(child: ModelSetupCard(services))),
                  Expanded(child: ChatPage(services)),
                ]),
                ListPage(() async => (await services.tasks.list(includeDone: true))
                    .map((t) => t.toString())
                    .toList()),
                ListPage(() async =>
                    (await services.memory.all()).map((m) => '[${m.category}] ${m.content}').toList()),
              ]),
            )),
  ));
}

class ChatPage extends StatefulWidget {
  final AppServices services;
  final bool closeOnEnd;
  const ChatPage(this.services, {this.closeOnEnd = false, super.key});
  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  late AssistantSession session;
  final log = <String>[];
  final input = TextEditingController();
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
    final onModel = session.engine is LlamaChannelEngine && session.engineInUse == session.engine.name;
    if (widget.services.modelLoad.value != ModelLoad.loaded ||
        onModel ||
        state != SessionState.listening) {
      return;
    }
    await session.close();
    if (!mounted) return;
    setState(() => log.add('(model loaded)'));
    _open();
  }

  Future<void> _open() async {
    session = widget.services.newSession(onIdleTimeout: _end);
    session.state.stream.listen((s) {
      if (mounted) setState(() => state = s);
    });
    await session.start();
    if (mounted) setState(() => log.add('(${session.engineInUse}) How can I help?'));
  }

  Future<void> _send() async {
    final text = input.text;
    input.clear();
    if (state != SessionState.listening || text.trim().isEmpty) return;
    setState(() => log.add('> $text'));
    final reply = await session.handle(text);
    if (mounted) setState(() => log.add(reply));
  }

  Future<void> _end() async {
    await session.close();
    if (widget.closeOnEnd) {
      await NativeBridge.closeActivity();
    } else if (mounted) {
      setState(() => log.add('(session ended)'));
      _open();
    }
  }

  @override
  void dispose() {
    widget.services.modelLoad.removeListener(_onModelLoad);
    session.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(children: [
        if (widget.closeOnEnd)
          Row(children: [
            Padding(padding: const EdgeInsets.all(12), child: Text(state.name)),
            const Spacer(),
            IconButton(icon: const Icon(Icons.close), onPressed: _end),
          ]),
        Expanded(
            child: ListView(
                padding: const EdgeInsets.all(12),
                children: [for (final l in log) Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Text(l))])),
        if (state == SessionState.processing) const LinearProgressIndicator(),
        Padding(
            padding: const EdgeInsets.all(8),
            child: TextField(
              controller: input,
              onSubmitted: (_) => _send(),
              decoration: InputDecoration(
                  hintText: 'Type (mic/ASR not integrated yet)',
                  suffixIcon: IconButton(icon: const Icon(Icons.send), onPressed: _send)),
            )),
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

/// Step-by-step model install guide; hidden once the model file is complete.
/// Re-checks whenever the app resumes (the user leaves to download/move the file).
class ModelSetupCard extends StatefulWidget {
  final AppServices services;
  const ModelSetupCard(this.services, {super.key});
  @override
  State<ModelSetupCard> createState() => _ModelSetupCardState();
}

class _ModelSetupCardState extends State<ModelSetupCard> with WidgetsBindingObserver {
  static const _folder = 'Documents/localmodels';
  ModelState? _state;

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
    final s = await widget.services.modelState();
    if (!mounted) return;
    setState(() => _state = s);
    // Ready on boot or just installed: load right away, once per app run (idle until then).
    if (s == ModelState.ready && widget.services.modelLoad.value == ModelLoad.idle) _load();
  }

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
    if (s == null) return const SizedBox.shrink();
    if (s == ModelState.ready) return const SizedBox.shrink();
    Widget step(int n, String text, [Widget? action]) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          CircleAvatar(radius: 11, child: Text('$n', style: const TextStyle(fontSize: 12))),
          const SizedBox(width: 10),
          Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(text),
            if (action != null) action,
          ])),
        ]));
    return Card(
        margin: const EdgeInsets.all(8),
        child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Set up the local model', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(s == ModelState.incomplete
                  ? 'A file named $modelFileName is in $_folder, but it is not $modelBytes bytes '
                      '(unfinished copy, or a different file). Replace it with the file from step 2.'
                  : 'Until it is installed the assistant uses simple built-in rules.'),
              step(1, 'Allow file access so the app can use $_folder.',
                  s == ModelState.noAccess
                      ? FilledButton(
                          onPressed: NativeBridge.requestStorageAccess,
                          child: const Text('Grant access'))
                      : const Text('Done.', style: TextStyle(color: Colors.green))),
              step(2, 'Download $modelFileName (about 365 MB, use Wi-Fi). Keep the file name exactly.',
                  OutlinedButton(
                      onPressed: () => NativeBridge.openUrl(modelUrl),
                      child: const Text('Open download page'))),
              step(3, 'When it finishes, open the Files app > Downloads, long-press the file, '
                  'choose Move to... and pick Documents > $_folder.'),
              step(4, 'Come back here. The app re-checks by itself and loads the model right away.',
                  TextButton(onPressed: _check, child: const Text('Check again'))),
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
                      ? const Icon(Icons.check_circle, color: Colors.green, size: 40)
                      : const Icon(Icons.error_outline, color: Colors.red, size: 40),
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
                        TextButton(onPressed: onRetry, child: const Text('Retry')),
                      TextButton(
                          onPressed: () => Navigator.of(context).pop(), child: const Text('OK')),
                    ],
            ));
      });
}
