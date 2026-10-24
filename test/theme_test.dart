import 'package:assistant/main.dart';
import 'package:assistant/theme/app_colors.dart';
import 'package:assistant/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('dark theme uses the brand palette and bundled font', () {
    final theme = AppTheme.dark;
    expect(theme.brightness, Brightness.dark);
    expect(theme.scaffoldBackgroundColor, AppColors.background);
    expect(theme.colorScheme.primary, AppColors.coreViolet);
    expect(theme.textTheme.bodyMedium!.fontFamily, 'PlusJakartaSans');
    expect(theme.textTheme.bodyMedium!.color, AppColors.ivory);
    expect(theme.textTheme.bodySmall!.color, AppColors.muted);
    expect(theme.filledButtonTheme.style!.shape!.resolve({}),
        isA<RoundedRectangleBorder>());
  });

  testWidgets('questionnaire renders with the dark theme at phone width',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.dark,
      home: WelcomeQuestionnaire(onSave: (_) async {}),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Save & start'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
