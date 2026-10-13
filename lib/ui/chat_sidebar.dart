import 'package:flutter/material.dart';
import '../data/repos.dart';

class ChatSidebar extends StatelessWidget {
  final List<ChatSummary> chats;
  final String? selectedId;
  final VoidCallback onNewChat;
  final ValueChanged<String> onSelect;
  final ValueChanged<ChatSummary> onDelete;
  final bool busy;
  final String? error;
  final VoidCallback? onRetry;

  const ChatSidebar({
    super.key,
    required this.chats,
    this.selectedId,
    required this.onNewChat,
    required this.onSelect,
    required this.onDelete,
    this.busy = false,
    this.error,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Material(
      color: colorScheme.surface,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16.0, 16.0, 16.0, 8.0),
              child: Text(
                'Your chats',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: colorScheme.onSurface,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: FilledButton.icon(
                onPressed: busy ? null : onNewChat,
                icon: const Icon(Icons.add),
                label: const Text('New chat'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
              ),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      error!,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colorScheme.error,
                      ),
                    ),
                    if (onRetry != null) ...[
                      const SizedBox(height: 8.0),
                      TextButton.icon(
                        onPressed: busy ? null : onRetry,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Retry'),
                        style: TextButton.styleFrom(
                          minimumSize: const Size(48, 48),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            Expanded(
              child: chats.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24.0),
                        child: Text(
                          'Your conversations stay on this device.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: chats.length,
                      itemBuilder: (context, index) {
                        final chat = chats[index];
                        final isSelected = chat.id == selectedId;

                        return ListTile(
                          selected: isSelected,
                          title: Text(
                            chat.title.trim().isEmpty ? 'New chat' : chat.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: busy ? null : () => onSelect(chat.id),
                          trailing: IconButton(
                            key: ValueKey('delete-${chat.id}'),
                            tooltip: 'Delete chat',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: busy ? null : () => onDelete(chat),
                            constraints: const BoxConstraints(
                              minWidth: 48,
                              minHeight: 48,
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
