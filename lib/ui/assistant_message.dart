import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../services/native_bridge.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

/// Mirrors MainActivity's openExternalLink check: https with a host only.
bool canOpenLink(String? href) {
  final uri = href == null ? null : Uri.tryParse(href.trim());
  return uri != null &&
      uri.scheme.toLowerCase() == 'https' &&
      uri.host.isNotEmpty;
}

Future<void> _open(BuildContext context, String url) async {
  try {
    await NativeBridge.openExternalLink(url);
  } catch (_) {
    // PlatformException (rejected / no browser) or MissingPluginException.
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(const SnackBar(content: Text('Could not open link')));
    }
  }
}

/// Renders assistant Markdown. Offline app: images are never fetched.
class AssistantMessage extends StatelessWidget {
  final String text;
  const AssistantMessage(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final body = theme.textTheme.bodyMedium!;
    final code = body.copyWith(
        fontFamily: 'monospace',
        fontSize: (body.fontSize ?? 16) * 0.88,
        color: AppColors.coreViolet,
        backgroundColor: AppColors.transparent);
    final quiet = BoxDecoration(
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        border: Border.all(color: AppColors.cardBorder));
    return MarkdownBody(
      data: text,
      selectable: true,
      softLineBreak: true,
      onTapLink: (_, href, __) {
        if (canOpenLink(href)) _open(context, href!.trim());
      },
      // Never show the source: it may be a huge data: URI.
      imageBuilder: (uri, title, alt) => Text(
          (alt ?? '').trim().isEmpty ? 'Image' : 'Image: ${alt!.trim()}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: body.copyWith(color: AppColors.muted)),
      styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
        p: body,
        strong: const TextStyle(
            fontWeight: FontWeight.w700, color: AppColors.ivory),
        em: const TextStyle(fontStyle: FontStyle.italic),
        a: const TextStyle(
            color: AppColors.coreViolet, decoration: TextDecoration.underline),
        h1: theme.textTheme.titleLarge!.copyWith(color: AppColors.coreViolet),
        h2: theme.textTheme.titleMedium!.copyWith(color: AppColors.coreViolet),
        h3: theme.textTheme.titleSmall!.copyWith(color: AppColors.coreViolet),
        listBullet: body.copyWith(color: AppColors.coreViolet),
        code: code,
        codeblockDecoration: quiet,
        codeblockPadding: const EdgeInsets.all(12),
        blockquote: body.copyWith(color: AppColors.muted),
        blockquoteDecoration: BoxDecoration(
            border: Border(
                left: BorderSide(
                    color: AppColors.coreViolet.withValues(alpha: 0.6),
                    width: 3))),
        blockquotePadding: const EdgeInsets.only(left: 12),
        tableHead: body.copyWith(
            fontWeight: FontWeight.w700, color: AppColors.coreViolet),
        tableBody: body,
        tableBorder:
            TableBorder.all(color: AppColors.coreViolet.withValues(alpha: 0.2)),
        tableCellsPadding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        // Intrinsic widths make the package wrap tables in a horizontal scroll.
        tableColumnWidth: const IntrinsicColumnWidth(),
        horizontalRuleDecoration: BoxDecoration(
            border: Border(
                top: BorderSide(
                    color: AppColors.coreViolet.withValues(alpha: 0.2)))),
      ),
    );
  }
}
