import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:assistant/mascot/mascot_emotion.dart';
import 'package:assistant/theme/app_colors.dart';
import 'package:assistant/ui/ghost_mascot.dart';
import 'package:assistant/ui/mascot_emotion_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

const _allEmotions = <MascotMood, MascotEmotion>{
  MascotMood.calm: MascotEmotion.calm,
  MascotMood.happy: MascotEmotion(MascotMood.happy, 0.75),
  MascotMood.excited: MascotEmotion(MascotMood.excited, 0.95),
  MascotMood.supportive: MascotEmotion(MascotMood.supportive, 0.8),
  MascotMood.concerned: MascotEmotion(MascotMood.concerned, 0.85),
  MascotMood.curious: MascotEmotion(MascotMood.curious, 0.55),
};

Future<Uint8List> _captureBytes(WidgetTester t, GlobalKey key) async {
  final boundary =
      key.currentContext!.findRenderObject() as RenderRepaintBoundary;
  final image = await t.runAsync(() => boundary.toImage(pixelRatio: 1.0));
  final data = await t.runAsync(
      () => image!.toByteData(format: ui.ImageByteFormat.rawRgba));
  image!.dispose();
  return data!.buffer.asUint8List();
}

int _pixelDiffCount(Uint8List a, Uint8List b) {
  var diff = 0;
  for (var i = 0; i < a.length; i += 4) {
    if ((a[i] - b[i]).abs() > 3 ||
        (a[i + 1] - b[i + 1]).abs() > 3 ||
        (a[i + 2] - b[i + 2]).abs() > 3 ||
        (a[i + 3] - b[i + 3]).abs() > 3) {
      diff++;
    }
  }
  return diff;
}

bool _hasOpaqueBorderPixel(Uint8List rgba, int width, int height) {
  int alphaAt(int x, int y) => rgba[(y * width + x) * 4 + 3];
  for (var x = 0; x < width; x++) {
    if (alphaAt(x, 0) > 0 || alphaAt(x, height - 1) > 0) return true;
  }
  for (var y = 0; y < height; y++) {
    if (alphaAt(0, y) > 0 || alphaAt(width - 1, y) > 0) return true;
  }
  return false;
}

void main() {
  testWidgets('ghost animates, tracks pointers and disposes cleanly',
      (t) async {
    await t.pumpWidget(
        const MaterialApp(home: Scaffold(body: Center(child: GhostMascot()))));
    expect(find.bySemanticsLabel('Corenyth ghost mascot'), findsOneWidget);
    await t.pump(const Duration(milliseconds: 800));
    final mouse = await t.createGesture(kind: ui.PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(650, 100));
    await mouse.moveTo(const Offset(700, 150));
    await t.pump(const Duration(milliseconds: 100));
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    await mouse.removePointer();
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  });

  testWidgets('reduced motion keeps the rendered ghost still', (t) async {
    final key = GlobalKey();
    await t.pumpWidget(MaterialApp(
        home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: Scaffold(
                body: Center(
                    child: RepaintBoundary(
                        key: key, child: const GhostMascot(size: 180)))))));
    final boundary =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final before = await t.runAsync(() => boundary.toImage());
    final first = await t.runAsync(() => before!.toByteData());
    await t.pump(const Duration(seconds: 2));
    await t.pumpAndSettle();
    final after = await t.runAsync(() => boundary.toImage());
    final second = await t.runAsync(() => after!.toByteData());
    expect(second!.buffer.asUint8List(), first!.buffer.asUint8List());
    before!.dispose();
    after!.dispose();
    expect(t.takeException(), isNull);
  });

  testWidgets('shared emotional target reaches every renderer and settles',
      (t) async {
    Widget view(MascotEmotion emotion, {bool reduced = false}) => MaterialApp(
        home: MediaQuery(
            data: MediaQueryData(disableAnimations: reduced),
            child: MascotEmotionScope(
                emotion: emotion,
                child: const Row(children: [
                  GhostMascot(animated: false),
                  GhostMascot(animated: false),
                ]))));
    List<MascotExpressionFrame> frames() => t
        .widgetList<CustomPaint>(find.descendant(
            of: find.byType(GhostMascot), matching: find.byType(CustomPaint)))
        .map((paint) =>
            (paint.painter as dynamic).expression() as MascotExpressionFrame)
        .toList();
    await t.pumpWidget(view(MascotEmotion.calm));
    await t.pumpWidget(view(const MascotEmotion(MascotMood.happy, 0.8)));
    await t.pump(const Duration(milliseconds: 325));
    expect(frames().length, 2);
    for (final frame in frames()) {
      expect(frame.weight(MascotMood.happy), closeTo(0.5, 0.05));
    }
    await t.pumpWidget(view(const MascotEmotion(MascotMood.concerned, 0.9)));
    expect(frames().first.weight(MascotMood.happy), closeTo(0.5, 0.05));
    await t.pumpAndSettle();
    expect(frames().first.weight(MascotMood.concerned), 1);
    await t.pumpWidget(
        view(const MascotEmotion(MascotMood.supportive, 0.7), reduced: true));
    await t.pumpAndSettle();
    expect(frames().first.weight(MascotMood.supportive), 1);
    expect(t.takeException(), isNull);
  });

  testWidgets(
      'all six expressions are pairwise distinct at 132, 30 and 18 without border clipping',
      (t) async {
    for (final size in [132.0, 30.0, 18.0]) {
      final snapshots = <MascotMood, Uint8List>{};
      final key = GlobalKey();
      for (final entry in _allEmotions.entries) {
        await t.pumpWidget(MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: Scaffold(
              backgroundColor: AppColors.transparent,
              body: Center(
                child: MascotEmotionScope(
                  emotion: entry.value,
                  child: RepaintBoundary(
                    key: key,
                    child: GhostMascot(size: size, animated: false),
                  ),
                ),
              ),
            ),
          ),
        ));
        await t.pump();
        final rgba = await _captureBytes(t, key);
        snapshots[entry.key] = rgba;
        final w = size.round();
        final h = (size * 1.35).round();
        expect(
          _hasOpaqueBorderPixel(rgba, w, h),
          isFalse,
          reason: '${entry.key.name} at size $size should not clip outer border',
        );
      }

      final moods = MascotMood.values;
      for (var i = 0; i < moods.length; i++) {
        for (var j = i + 1; j < moods.length; j++) {
          final diff =
              _pixelDiffCount(snapshots[moods[i]]!, snapshots[moods[j]]!);
          expect(
            diff,
            greaterThan(0),
            reason:
                '${moods[i].name} and ${moods[j].name} must be visually distinct at size $size',
          );
        }
      }
    }
  });

  testWidgets(
      'mixed transitions and intensity modulation blend smoothly without resetting float clock',
      (t) async {
    final key = GlobalKey();
    Widget buildScene(MascotEmotion emotion) => MaterialApp(
          home: Scaffold(
            backgroundColor: AppColors.surface,
            body: Center(
              child: MascotEmotionScope(
                emotion: emotion,
                child: RepaintBoundary(
                  key: key,
                  child: const GhostMascot(size: 132, animated: true),
                ),
              ),
            ),
          ),
        );

    double readClock() {
      final paint = t.widget<CustomPaint>(find.descendant(
          of: find.byType(GhostMascot), matching: find.byType(CustomPaint)));
      return ((paint.painter as dynamic).clock as Animation<double>).value;
    }

    await t.pumpWidget(buildScene(MascotEmotion.calm));
    await t.pump(const Duration(milliseconds: 1400));
    final clockBeforeTransition = readClock();
    expect(clockBeforeTransition, greaterThan(0));

    // Start transition to happy; verify clock does not reset to 0.
    await t.pumpWidget(buildScene(const MascotEmotion(MascotMood.happy, 0.85)));
    expect(readClock(), closeTo(clockBeforeTransition, 0.001));

    await t.pump(const Duration(milliseconds: 325));
    final clockMidTransition = readClock();
    expect(clockMidTransition, greaterThan(clockBeforeTransition));
    final midHappyBytes = await _captureBytes(t, key);

    // Interrupt mid-transition with supportive; verify three-way blended frame renders.
    await t.pumpWidget(
        buildScene(const MascotEmotion(MascotMood.supportive, 0.8)));
    await t.pump(const Duration(milliseconds: 160));
    final paint = t.widget<CustomPaint>(find.descendant(
        of: find.byType(GhostMascot), matching: find.byType(CustomPaint)));
    final frame =
        (paint.painter as dynamic).expression() as MascotExpressionFrame;
    expect(frame.weight(MascotMood.calm), greaterThan(0.05));
    expect(frame.weight(MascotMood.happy), greaterThan(0.05));
    expect(frame.weight(MascotMood.supportive), greaterThan(0.05));
    final threeWayBytes = await _captureBytes(t, key);
    expect(_pixelDiffCount(midHappyBytes, threeWayBytes), greaterThan(20));

    // Check intensity scaling on static happy expression.
    final staticKey = GlobalKey();
    Future<Uint8List> captureStatic(MascotEmotion emotion) async {
      await t.pumpWidget(MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: MascotEmotionScope(
            emotion: emotion,
            child: RepaintBoundary(
              key: staticKey,
              child: const GhostMascot(size: 132, animated: false),
            ),
          ),
        ),
      ));
      await t.pump();
      return _captureBytes(t, staticKey);
    }

    final calmBytes = await captureStatic(MascotEmotion.calm);
    final mildHappy =
        await captureStatic(const MascotEmotion(MascotMood.happy, 0.25));
    final strongHappy =
        await captureStatic(const MascotEmotion(MascotMood.happy, 0.95));
    expect(
      _pixelDiffCount(calmBytes, strongHappy),
      greaterThan(_pixelDiffCount(calmBytes, mildHappy)),
    );
  });

  testWidgets(
      'celebratory bounce triggers once on entering excited and respects animated/reduced-motion',
      (t) async {
    Widget buildAnimated(MascotEmotion emotion,
            {bool animated = true, bool reduced = false, int rebuildTick = 0}) =>
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: reduced),
            child: MascotEmotionScope(
              emotion: emotion,
              child: Column(
                children: [
                  Text('tick-$rebuildTick'),
                  GhostMascot(size: 132, animated: animated),
                ],
              ),
            ),
          ),
        );

    Animation<double> bounceController() {
      final paint = t.widget<CustomPaint>(find.descendant(
          of: find.byType(GhostMascot), matching: find.byType(CustomPaint)));
      return (paint.painter as dynamic).bounce as Animation<double>;
    }

    await t.pumpWidget(buildAnimated(MascotEmotion.calm));
    expect(bounceController().value, 0.0);

    // Entering excited starts the single-shot celebratory bounce.
    await t.pumpWidget(
        buildAnimated(const MascotEmotion(MascotMood.excited, 0.95)));
    await t.pump(const Duration(milliseconds: 250));
    expect(bounceController().value, greaterThan(0.1));
    expect(bounceController().value, lessThan(0.9));

    // Once the 700ms bounce finishes, it settles at 1.0 and does not re-trigger on rebuilds.
    await t.pump(const Duration(milliseconds: 600));
    expect(bounceController().value, 1.0);

    await t.pumpWidget(buildAnimated(
        const MascotEmotion(MascotMood.excited, 0.95),
        rebuildTick: 1));
    await t.pump(const Duration(milliseconds: 200));
    expect(bounceController().value, 1.0);

    // Reduced motion and animated: false suppress celebratory bounce.
    await t.pumpWidget(buildAnimated(MascotEmotion.calm, reduced: true));
    await t.pumpWidget(buildAnimated(
        const MascotEmotion(MascotMood.excited, 0.95),
        reduced: true));
    await t.pump(const Duration(milliseconds: 250));
    expect(bounceController().value, 0.0);
  });

  testWidgets('renders six-state comparison preview sheet at fixed phase',
      (t) async {
    t.view.physicalSize = const Size(980, 620);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);

    final previewKey = GlobalKey();
    await t.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      home: MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: Scaffold(
          backgroundColor: AppColors.surface,
          body: RepaintBoundary(
            key: previewKey,
            child: Container(
              color: AppColors.surface,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      for (final entry in _allEmotions.entries)
                        MascotEmotionScope(
                          emotion: entry.value,
                          child: Container(
                            width: 146,
                            padding: const EdgeInsets.symmetric(
                                vertical: 16, horizontal: 8),
                            decoration: BoxDecoration(
                              color: AppColors.surfaceRaised,
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color:
                                    AppColors.lavender.withValues(alpha: 0.16),
                              ),
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const GhostMascot(size: 132, animated: false),
                                const SizedBox(height: 14),
                                const Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    GhostMascot(size: 30, animated: false),
                                    SizedBox(width: 14),
                                    GhostMascot(size: 18, animated: false),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  entry.key.name.toUpperCase(),
                                  style: const TextStyle(
                                    color: AppColors.ivory,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    letterSpacing: 1.1,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ));
    await t.pump();

    final boundary =
        previewKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await t.runAsync(() => boundary.toImage(pixelRatio: 2.0));
    final pngBytes =
        await t.runAsync(() => image!.toByteData(format: ui.ImageByteFormat.png));
    image!.dispose();
    expect(pngBytes, isNotNull);

    final file = File('build/ghost_mascot_six_states_preview.png');
    await t.runAsync(() async {
      await file.parent.create(recursive: true);
      await file.writeAsBytes(pngBytes!.buffer.asUint8List());
    });
    expect(file.existsSync(), isTrue);
  });
}
