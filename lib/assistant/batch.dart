/// The caller's batch limit; the reader deliberately preserves larger lists.
const maxBatchItems = 10;

class BatchItem {
  final String text;
  final String? section;

  const BatchItem(this.text, this.section);
}

class BatchRequest {
  final List<BatchItem> items;
  final bool explicit;

  const BatchRequest(this.items, {required this.explicit});
}

final _header = RegExp(
  r'^(?:add these tasks\b|add the following\b|tasks\s*:|remind me about these\b)\s*:?\s*',
  caseSensitive: false,
);
final _bullet = RegExp(r'^\s*(?:[-*•]|\d+[.)])(?:\s+|$)');
final _section = RegExp(r'^(?:\*\*(.+?)\*\*|__(.+?)__)$');
final _join = RegExp(
  r'\b(?:and|then|also|plus)\s+(?:then\s+|also\s+)?(?:i\s+(?:also\s+)?(?:need|have)\s+to\s+)?'
  r'(?=(?:buy|call|email|text|pay|book|send|pick up|clean|submit|visit|meet|go|finish|write|cook|wash)\b)',
  caseSensitive: false,
);

String _stripMarkdown(String text) =>
    text.replaceAll('**', '').replaceAll('__', '').replaceAll('#', '').trim();

/// Returns null unless [text] holds at least two separable items.
BatchRequest? readBatch(String text) {
  final items = <BatchItem>[];
  final prose = <String>[];
  String? section;
  var explicit = false;

  for (var line in text.split(RegExp(r'\r?\n'))) {
    line = line.trim();
    if (line.isEmpty || line == '*') continue;

    // Remove heading markers before testing an explicit request or section.
    line = line.replaceAll('#', '').trim();
    final header = _header.firstMatch(_stripMarkdown(line));
    if (header != null) {
      explicit = true;
      // Keep the original bold markers for an inline section after the header.
      final rawHeader = _header.firstMatch(line);
      line = rawHeader == null
          ? _stripMarkdown(line).substring(header.end)
          : line.substring(rawHeader.end).trim();
      if (line.isEmpty) continue;
    }

    final heading = _section.firstMatch(line);
    if (heading != null) {
      section = _stripMarkdown(heading.group(1) ?? heading.group(2)!);
      continue;
    }

    final bullet = _bullet.firstMatch(line);
    if (bullet != null) {
      final value = _stripMarkdown(line.substring(bullet.end));
      if (value.isNotEmpty && value != '*') {
        items.add(BatchItem(value, section));
      }
    } else {
      final value = _stripMarkdown(line);
      if (value.isNotEmpty) prose.add(value);
    }
  }

  if (items.length >= 2) return BatchRequest(items, explicit: explicit);
  // Conjunctions are only a fallback for short, single-line messages.
  if (items.isEmpty && prose.length == 1 && prose.single.length <= 500) {
    final message = prose.single.replaceFirst(
      RegExp(r'^add\s+', caseSensitive: false),
      '',
    );
    final parts = message.split(_join).map((part) => part.trim()).toList();
    if (parts.length >= 2 && parts.every((part) => part.isNotEmpty)) {
      return BatchRequest(
        parts.map((part) => BatchItem(part, section)).toList(),
        explicit: explicit,
      );
    }
  }
  return null;
}
