import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../mascot/mascot_emotion.dart';
import '../data/repos.dart';
import '../theme/app_colors.dart';
import 'mascot_emotion_scope.dart';
import 'assistant_message.dart';
import 'ghost_mascot.dart';

/// One user turn and its reply; proactive assistant messages stand on their own.
class _Exchange {
  final List<Message> messages;
  final int end;
  _Exchange(this.messages, this.end);
}

List<_Exchange> _exchanges(List<Message> messages, String? streaming) {
  final result = <_Exchange>[];
  for (var i = 0; i < messages.length; i++) {
    final message = messages[i];
    if (message.role == 'assistant' &&
        message.kind == null &&
        result.isNotEmpty &&
        result.last.messages.first.role == 'user' &&
        result.last.messages.length == 1) {
      final previous = result.removeLast();
      result.add(_Exchange([...previous.messages, message], i + 1));
    } else {
      result.add(_Exchange([message], i + 1));
    }
  }
  if (streaming != null) {
    final draft = Message('assistant', streaming);
    if (result.isNotEmpty &&
        result.last.messages.first.role == 'user' &&
        result.last.messages.length == 1) {
      final previous = result.removeLast();
      result.add(_Exchange([...previous.messages, draft], messages.length));
    } else {
      result.add(_Exchange([draft], messages.length));
    }
  }
  return result;
}

class ChatView extends StatefulWidget {
  final String name;
  final List<Message> messages;
  final TextEditingController input;
  // Retained for caller compatibility; paging owns history scrolling now.
  final ScrollController scroll;
  final bool busy, ready;
  final VoidCallback onSend;
  final Widget? status;
  final VoidCallback? onStop;
  final String? streamingText;
  final ValueChanged<MascotEmotion>? onEmotionChanged;
  const ChatView(
      {required this.name,
      required this.messages,
      required this.input,
      required this.scroll,
      required this.busy,
      required this.ready,
      required this.onSend,
      this.status,
      this.onStop,
      this.streamingText,
      this.onEmotionChanged,
      super.key});
  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  late List<_Exchange> _turns;
  late final PageController _pages;
  int _selected = 0;
  int _userTurns = 0;
  bool _paging = false;
  int? _pendingPage;
  double? _restingMascotHeight;
  Size? _mascotViewport;
  double _overscroll = 0;

  void _read() {
    _turns = _exchanges(widget.messages, widget.streamingText);
  }

  int get _users => widget.messages.where((m) => m.role == 'user').length;
  MascotEmotion get _emotion => const MascotEmotionInterpreter().interpret(
      widget.messages.take(_turns.isEmpty ? 0 : _turns[_selected].end));

  @override
  void initState() {
    super.initState();
    _read();
    _selected = math.max(0, _turns.length - 1);
    _userTurns = _users;
    _pages = PageController(initialPage: _selected);
  }

  @override
  void didUpdateWidget(covariant ChatView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previousCount = _turns.length;
    final wasLatest = _selected >= previousCount - 1;
    _read();
    final submitted = _users > _userTurns;
    _userTurns = _users;
    final next = submitted || wasLatest
        ? math.max(0, _turns.length - 1)
        : _selected.clamp(0, math.max(0, _turns.length - 1)).toInt();
    if (next != _selected) {
      _selected = next;
      _pendingPage = next;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_pages.hasClients) _pages.jumpToPage(next);
        setState(() => _selected = next);
        widget.onEmotionChanged?.call(_emotion);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _pendingPage = null;
        });
      });
    }
  }

  void _view(int index) {
    if (_pendingPage != null && index != _pendingPage) return;
    setState(() {
      _selected = index;
      _overscroll = 0;
    });
    widget.onEmotionChanged?.call(_emotion);
  }

  Future<void> _go(int index) async {
    if (_paging || !_pages.hasClients || index < 0 || index >= _turns.length)
      return;
    _paging = true;
    try {
      if (MediaQuery.disableAnimationsOf(context)) {
        _pages.jumpToPage(index);
      } else {
        await _pages.animateToPage(index,
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutCubic);
      }
    } finally {
      _paging = false;
    }
  }

  bool _edge(ScrollNotification notification, int index) {
    if (notification.depth != 0) return false;
    if (notification is ScrollStartNotification) _overscroll = 0;
    if (notification is OverscrollNotification &&
        notification.dragDetails != null) {
      _overscroll += notification.overscroll;
      if (_overscroll.abs() > 44) {
        _go(index + (_overscroll > 0 ? 1 : -1));
        _overscroll = 0;
      }
    }
    return false;
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MascotEmotionScope(
        emotion: _emotion,
        child: Column(children: [
          if (widget.status != null) widget.status!,
          Expanded(child: LayoutBuilder(builder: (context, bounds) {
            final view = View.of(context);
            final keyboardHeight =
                view.viewInsets.bottom / view.devicePixelRatio;
            final viewport = view.physicalSize / view.devicePixelRatio;
            // Remember the resting size: Scaffold resizes for the keyboard and
            // the navigation dock may disappear, neither should resize the ghost.
            if (keyboardHeight == 0 ||
                _mascotViewport != viewport ||
                _restingMascotHeight == null) {
              final restingHeight = bounds.maxHeight + keyboardHeight;
              _restingMascotHeight = math.min(
                  restingHeight * (restingHeight < 440 ? 0.12 : 0.22),
                  restingHeight < 440 ? 64.0 : 160.0);
              _mascotViewport = viewport;
            }
            // Only yield space on exceptionally short windows to keep input usable.
            final mascotHeight = math.min(
                _restingMascotHeight!, math.max(0.0, bounds.maxHeight - 160));
            return Column(children: [
              SizedBox(
                  key: const ValueKey('mascot-stage'),
                  height: mascotHeight,
                  child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: LayoutBuilder(
                          builder: (context, space) => Center(
                                  child: GhostMascot(
                                key: const ValueKey('conversation-mascot'),
                                size: math.max(
                                    0,
                                    math.min(space.maxWidth,
                                        space.maxHeight / 1.35)),
                              ))))),
              Expanded(
                  child: Column(children: [
                if (_turns.isNotEmpty)
                  SizedBox(
                      height: 32,
                      child: Row(children: [
                        IconButton(
                            tooltip: 'Previous exchange',
                            padding: EdgeInsets.zero,
                            onPressed:
                                _selected > 0 ? () => _go(_selected - 1) : null,
                            icon: const Icon(Icons.keyboard_arrow_up_rounded,
                                size: 20)),
                        Expanded(
                            child: Text(
                                'Exchange ${_selected + 1} of ${_turns.length}',
                                textAlign: TextAlign.center,
                                style: Theme.of(context).textTheme.labelSmall)),
                        IconButton(
                            tooltip: 'Next exchange',
                            padding: EdgeInsets.zero,
                            onPressed: _selected < _turns.length - 1
                                ? () => _go(_selected + 1)
                                : null,
                            icon: const Icon(Icons.keyboard_arrow_down_rounded,
                                size: 20)),
                      ])),
                Expanded(
                    child: _turns.isEmpty
                        ? _welcome(context)
                        : PageView.builder(
                            key: const ValueKey('exchange-pager'),
                            controller: _pages,
                            scrollDirection: Axis.vertical,
                            onPageChanged: _view,
                            itemCount: _turns.length,
                            itemBuilder: (context, index) =>
                                NotificationListener<ScrollNotification>(
                              onNotification: (notification) =>
                                  _edge(notification, index),
                              child: SingleChildScrollView(
                                key: PageStorageKey('exchange-$index'),
                                physics: const ClampingScrollPhysics(
                                    parent: AlwaysScrollableScrollPhysics()),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 4),
                                child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      for (final message
                                          in _turns[index].messages)
                                        _MessageBubble(message)
                                    ]),
                              ),
                            ),
                          )),
                if (widget.busy)
                  Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(children: [
                        Expanded(
                            child: Text(
                                widget.streamingText == null
                                    ? 'Corenyth is thinking…'
                                    : 'Corenyth is replying…',
                                style: Theme.of(context).textTheme.bodySmall)),
                        if (widget.onStop != null)
                          TextButton(
                              onPressed: widget.onStop,
                              child: const Text('Stop')),
                      ])),
                _composer(context),
              ])),
            ]);
          })),
        ]),
      );

  Widget _composer(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: ValueListenableBuilder<TextEditingValue>(
            valueListenable: widget.input,
            builder: (context, value, _) => TextField(
                  key: const ValueKey('chat-composer'),
                  controller: widget.input,
                  minLines: 1,
                  maxLines: 3,
                  textCapitalization: TextCapitalization.sentences,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) {
                    if (widget.ready && !widget.busy) widget.onSend();
                  },
                  decoration: InputDecoration(
                      hintText: 'Message Corenyth…',
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                      suffixIcon: IconButton.filled(
                          tooltip: 'Send message',
                          onPressed: widget.ready &&
                                  !widget.busy &&
                                  value.text.trim().isNotEmpty
                              ? widget.onSend
                              : null,
                          style: IconButton.styleFrom(
                              backgroundColor: AppColors.lavender,
                              foregroundColor: AppColors.surface),
                          icon: const Icon(Icons.arrow_upward_rounded,
                              size: 22))),
                )),
      );

  Widget _welcome(BuildContext context) => SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(children: [
          Text(
              widget.name.trim().isEmpty
                  ? 'A little space to think.'
                  : 'Hello, ${widget.name.trim()}.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final prompt in ['What tasks do I have?', 'Help me plan my day'])
            TextButton(
                onPressed: widget.ready && !widget.busy
                    ? () {
                        widget.input.text = prompt;
                        widget.onSend();
                      }
                    : null,
                child: Text(prompt)),
        ]),
      );
}

class _MessageBubble extends StatelessWidget {
  final Message message;
  const _MessageBubble(this.message);
  @override
  Widget build(BuildContext context) {
    final user = message.role == 'user';
    final sentAt = message.createdAt?.toLocal();
    final locale = MaterialLocalizations.of(context);
    final label = switch (message.kind) {
      'pre' || 'nudge' => 'Preparation nudge',
      'follow_up' => 'Follow-up',
      'evening_review' || 'review' => 'Your day',
      'daily' => 'Daily reminder',
      'reminder' => 'Reminder',
      _ => null,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
          crossAxisAlignment:
              user ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            if (!user)
              Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 8),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Image.asset('assets/branding/corenyth-logo-dark.png',
                        width: 22, height: 26, excludeFromSemantics: true),
                    const SizedBox(width: 8),
                    Text('CORENYTH',
                        style: Theme.of(context)
                            .textTheme
                            .labelSmall!
                            .copyWith(color: AppColors.muted)),
                  ])),
            if (label != null)
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 8),
                child: Text(
                  '$label${message.taskId == null ? '' : ' · Task #${message.taskId}'}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            FractionallySizedBox(
                widthFactor: user ? 0.88 : 1,
                alignment: user ? Alignment.centerRight : Alignment.centerLeft,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                      color: user ? AppColors.surfaceRaised : AppColors.surface,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                          color: AppColors.lavender
                              .withValues(alpha: user ? 0.08 : 0.12))),
                  child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: user
                          ? SelectableText(message.content,
                              style: Theme.of(context).textTheme.bodyLarge)
                          : AssistantMessage(message.content)),
                )),
            if (sentAt != null)
              Padding(
                padding: const EdgeInsets.only(left: 4, right: 4, top: 8),
                child: Text(
                  '${locale.formatMediumDate(sentAt)} · '
                  '${locale.formatTimeOfDay(TimeOfDay.fromDateTime(sentAt), alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context))}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppColors.muted,
                      ),
                ),
              ),
          ]),
    );
  }
}
