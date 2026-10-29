import 'package:assistant/ui/stream_coalescer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('chunks merge into frame-rate updates, not per-token rebuilds',
      (t) async {
    final flushed = <String>[];
    final c = StreamCoalescer(flushed.add);
    // The first add flushes at once; a burst within one interval merges to a
    // single later update carrying the latest cumulative text.
    c.add('He');
    expect(flushed, ['He']);
    c.add('Hey');
    c.add('Hey t');
    expect(flushed, hasLength(1), reason: 'the burst is batched');
    await t.pump(const Duration(milliseconds: 40));
    expect(flushed, ['He', 'Hey t']);
    expect(c.cancelled, isFalse);
  });

  testWidgets('cancel drops pending text: the final bubble supersedes the draft',
      (t) async {
    final flushed = <String>[];
    final c = StreamCoalescer(flushed.add);
    c.add('partial');
    c.add('partial answer');
    expect(flushed, hasLength(1));
    c.cancel();
    await t.pump(const Duration(milliseconds: 40));
    expect(flushed, hasLength(1),
        reason: 'a pending batch never fires after cancel');
    c.add('late'); // a late chunk after stop reaches nobody
    await t.pump(const Duration(milliseconds: 40));
    expect(flushed, hasLength(1));
    expect(c.cancelled, isTrue);
  });

  testWidgets('withdrawal (empty text) reaches the UI', (t) async {
    final flushed = <String>[];
    final c = StreamCoalescer(flushed.add);
    c.add('shown');
    c.add('');
    await t.pump(const Duration(milliseconds: 40));
    expect(flushed, ['shown', ''],
        reason: 'an empty live text clears the draft');
  });
}
