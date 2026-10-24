import 'package:flutter/material.dart';
import '../data/repos.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import 'glass_surface.dart';

class ChatSidebar extends StatelessWidget {
  final List<ChatSummary> chats;
  final String? selectedId;
  final VoidCallback onNewChat;
  final ValueChanged<String> onSelect;
  final ValueChanged<ChatSummary> onDelete;
  final bool busy;
  final String? error;
  final VoidCallback? onRetry;

  /// Shown as "Add home screen widget" at the bottom when set.
  final VoidCallback? onAddWidget;

  /// Shown as "Send feedback" above the widget option when set.
  final VoidCallback? onFeedback;

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
    this.onAddWidget,
    this.onFeedback,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Material(
      color: AppColors.transparent,
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
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: Text(
                'Chats share context. Check-ins arrive in your main chat.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
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

                        final tile = ListTile(
                          contentPadding:
                              const EdgeInsets.only(left: 10, right: 2),
                          leading: Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                  color: isSelected
                                      ? AppColors.selectedIcon
                                      : AppColors.glassFill,
                                  borderRadius:
                                      BorderRadius.circular(AppTheme.radiusSm),
                                  border: Border.all(
                                      color: isSelected
                                          ? AppColors.selectedBorder
                                          : AppColors.hairline)),
                              child: Icon(Icons.chat_bubble_outline_rounded,
                                  size: 18,
                                  color: isSelected
                                      ? AppColors.coreViolet
                                      : AppColors.tertiaryText)),
                          textColor: AppColors.muted,
                          selectedColor: AppColors.ivory,
                          selectedTileColor: AppColors.transparent,
                          key: ValueKey('chat-${chat.id}'),
                          selected: isSelected,
                          title: Text(
                            chat.id == ConversationRepo.mainChatId
                                ? 'Main chat'
                                : chat.title.trim().isEmpty
                                    ? 'New chat'
                                    : chat.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: chat.id == ConversationRepo.mainChatId
                              ? const Text('Daily reviews and check-ins',
                                  maxLines: 1, overflow: TextOverflow.ellipsis)
                              : null,
                          onTap: busy ? null : () => onSelect(chat.id),
                          trailing:
                              Row(mainAxisSize: MainAxisSize.min, children: [
                            if (!isSelected)
                              Text(
                                  '${chat.updatedAt.toLocal().day}/${chat.updatedAt.toLocal().month}',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                      color: AppColors.tertiaryText)),
                            IconButton(
                              key: ValueKey('delete-${chat.id}'),
                              tooltip: 'Delete chat',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: busy ? null : () => onDelete(chat),
                              constraints: const BoxConstraints(
                                minWidth: 48,
                                minHeight: 48,
                              ),
                            ),
                          ]),
                        );
                        return Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 2),
                            child: isSelected
                                ? GlassSurface(
                                    // The drawer already filters the backdrop once.
                                    blur: false,
                                    radius: BorderRadius.circular(
                                        AppTheme.radiusMd),
                                    child: tile)
                                : tile);
                      },
                    ),
            ),
            if (onFeedback != null || onAddWidget != null)
              const Divider(height: 1),
            if (onFeedback != null)
              ListTile(
                leading: Icon(Icons.feedback_outlined, color: AppColors.muted),
                title: const Text('Send feedback'),
                subtitle: const Text('Opens your mail app'),
                onTap: onFeedback,
              ),
            if (onAddWidget != null) ...[
              ListTile(
                leading: Icon(Icons.widgets_outlined, color: AppColors.muted),
                title: const Text('Add home screen widget'),
                subtitle: const Text('Your tasks at a glance, one tap to chat'),
                onTap: onAddWidget,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
