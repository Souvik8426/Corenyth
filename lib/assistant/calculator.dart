/// A small arithmetic parser; no code evaluation or model-generated arithmetic.
String? calculate(String text) {
  var expression = text.trim().replaceFirst(
      RegExp(r'^(?:what is|what\x27s|whats|calculate|compute)\s+',
          caseSensitive: false), '');
  expression = expression
      .replaceAll(RegExp(r'[?=]+$'), '')
      .replaceAll('×', '*')
      .replaceAll('÷', '/')
      .replaceAll(RegExp(r'\s+times\s+', caseSensitive: false), '*')
      .replaceAll(RegExp(r'\s+x\s+', caseSensitive: false), '*');
  if (!RegExp(r'^[\d\s.()+*/\-]+$').hasMatch(expression) ||
      !RegExp(r'\d').hasMatch(expression) ||
      !RegExp(r'[+*/\-]').hasMatch(expression)) {
    return null;
  }
  if (expression.length > 200) return 'Please use a shorter calculation.';
  try {
    final parser = _Arithmetic(expression.replaceAll(RegExp(r'\s'), ''));
    final result = parser.sum();
    if (parser.i != parser.s.length || !result.isFinite) {
      throw const FormatException();
    }
    final shown = expression.trim();
    final out =
        result == result.roundToDouble() ? result.toInt() : result;
    return '$shown = $out.';
  } on FormatException {
    return 'I couldn’t calculate that. Check the expression (and avoid dividing by zero).';
  }
}

class _Arithmetic {
  final String s;
  int i = 0;
  _Arithmetic(this.s);
  bool take(String c) {
    if (i < s.length && s[i] == c) {
      i++;
      return true;
    }
    return false;
  }

  double sum() {
    var n = product();
    while (i < s.length) {
      if (take('+')) {
        n += product();
      } else if (take('-')) {
        n -= product();
      } else {
        break;
      }
    }
    return n;
  }

  double product() {
    var n = atom();
    while (i < s.length) {
      if (take('*')) {
        n *= atom();
      } else if (take('/')) {
        n /= atom();
      } else {
        break;
      }
    }
    return n;
  }

  double atom() {
    if (take('-')) return -atom();
    if (take('+')) return atom();
    if (take('(')) {
      final n = sum();
      if (!take(')')) throw const FormatException();
      return n;
    }
    final start = i;
    while (i < s.length && RegExp(r'[\d.]').hasMatch(s[i])) {
      i++;
    }
    if (start == i) throw const FormatException();
    return double.parse(s.substring(start, i));
  }
}
