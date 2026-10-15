import 'package:flutter/material.dart';

import '../data/repos.dart';
import '../theme/app_colors.dart';
import 'assistant_message.dart';

/// Presentation only: messages and submission stay owned by the real session.
class ChatView extends StatelessWidget {
  final String name;
  final List<Message> messages;
  final TextEditingController input;
  final ScrollController scroll;
  final bool busy;
  final bool ready;
  final VoidCallback onSend;
  final Widget? status;
  final VoidCallback? onStop;
  final String? streamingText;
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
      super.key});

  @override
  Widget build(BuildContext context) => Column(children: [
        if (status != null) status!,
        Expanded(
          child: messages.isEmpty
              ? _welcome(context)
              : ListView.builder(
                  controller: scroll,
                  padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
                  itemCount: messages.length + (streamingText == null ? 0 : 1),
                  itemBuilder: (context, index) => _MessageBubble(
                      index == messages.length
                          ? Message('assistant', streamingText!)
                          : messages[index])),
        ),
        if (busy)
          Padding(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 12),
              child: Row(children: [
                const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                      streamingText == null
                          ? 'Corenyth is thinking…'
                          : 'Corenyth is replying…',
                      style: Theme.of(context).textTheme.bodySmall),
                ),
                if (onStop != null)
                  TextButton.icon(
                      onPressed: onStop,
                      icon: const Icon(Icons.stop_rounded),
                      label: const Text('Stop')),
              ])),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: ValueListenableBuilder<TextEditingValue>(
              valueListenable: input,
              builder: (context, value, _) => TextField(
                    key: const ValueKey('chat-composer'),
                    controller: input,
                    minLines: 1,
                    maxLines: 5,
                    textCapitalization: TextCapitalization.sentences,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) {
                      if (ready && !busy) onSend();
                    },
                    decoration: InputDecoration(
                      hintText: 'Message Corenyth…',
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 16),
                      suffixIcon: Padding(
                          padding: const EdgeInsets.all(6),
                          child: IconButton.filled(
                            tooltip: 'Send message',
                            onPressed:
                                ready && !busy && value.text.trim().isNotEmpty
                                    ? onSend
                                    : null,
                            style: IconButton.styleFrom(
                                backgroundColor: AppColors.lavender,
                                foregroundColor: AppColors.surface,
                                minimumSize: const Size(48, 48)),
                            icon: const Icon(Icons.arrow_upward_rounded,
                                size: 22),
                          )),
                    ),
                  )),
        ),
      ]);

  Widget _welcome(BuildContext context) => LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
            controller: scroll,
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                  minHeight:
                      (constraints.maxHeight - 40).clamp(0, double.infinity)),
              child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                        child: Container(
                            width: 64,
                            height: 64,
                            decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: AppColors.coreGradient,
                                boxShadow: [
                                  BoxShadow(
                                      color: AppColors.lavender
                                          .withValues(alpha: 0.16),
                                      blurRadius: 36,
                                      spreadRadius: 4)
                                ]),
                            child: const Icon(Icons.auto_awesome_rounded,
                                color: AppColors.surface, size: 28))),
                    const SizedBox(height: 24),
                    Text(
                        name.trim().isEmpty
                            ? 'A little space to think.'
                            : 'Hello, ${name.trim()}.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineMedium),
                    const SizedBox(height: 8),
                    Text('Clear your mind. Make room for what matters.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context)
                            .textTheme
                            .bodyMedium!
                            .copyWith(color: AppColors.muted)),
                    const SizedBox(height: 32),
                    Align(
                        alignment: Alignment.center,
                        child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 400),
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  _prompt(
                                      context,
                                      Icons.check_circle_outline_rounded,
                                      'What tasks do I have?'),
                                  const SizedBox(height: 12),
                                  _prompt(
                                      context,
                                      Icons.lightbulb_outline_rounded,
                                      'Help me plan my day'),
                                ]))),
                  ]),
            ),
          ));

  Widget _prompt(BuildContext context, IconData icon, String text) =>
      OutlinedButton(
        onPressed: ready && !busy
            ? () {
                input.text = text;
                onSend();
              }
            : null,
        style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            minimumSize: const Size(48, 52)),
        child: Row(children: [
          Icon(icon, size: 20, color: AppColors.lavender),
          const SizedBox(width: 12),
          Expanded(child: Text(text)),
          const SizedBox(width: 8),
          const Icon(Icons.north_east_rounded, size: 16, color: AppColors.muted)
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
                    const Icon(Icons.auto_awesome_rounded,
                        size: 14, color: AppColors.gold),
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
