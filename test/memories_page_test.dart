import 'package:assistant/data/repos.dart';
import 'package:assistant/theme/app_theme.dart';
import 'package:assistant/ui/memories_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';

class _Database extends Fake implements Database {}

Memory _memory(int id, String content, [String category = 'fact']) => Memory({
      'id': id,
      'content': content,
      'category': category,
      'importance': 0.5,
    });

class _Memories extends MemoryRepo {
  _Memories([List<Memory>? initial]) : super(_Database()) {
    rows = initial ?? [];
  }
  late List<Memory> rows;
  bool failLoad = false;
  bool failAdd = false;
  bool failDelete = false;
  bool ignoreAdd = false;
  bool ignoreDelete = false;
  int reads = 0;
  int searchCalls = 0;

  @override
  Future<List<Memory>> all() async {
    reads++;
    if (failLoad) throw StateError('Read unavailable');
    return List.of(rows);
  }

  @override
  Future<int> add(String content,
      {String category = 'fact', double importance = 0.5, String? opId, String? source}) async {
    if (failAdd) throw StateError('Write unavailable');
    final id = rows.isEmpty ? 1 : rows.last.id + 1;
    if (!ignoreAdd) rows.add(_memory(id, content, category));
    return id;
  }

  @override
  Future<bool> delete(int id) async {
    if (failDelete) throw StateError('Delete unavailable');
    if (!ignoreDelete) rows.removeWhere((memory) => memory.id == id);
    return true;
  }

  @override
  Future<List<Memory>> search(String query, {int limit = 3}) async {
    searchCalls++;
    throw StateError('The screen must filter locally');
  }
}

class _Profiles extends ProfileRepo {
  _Profiles() : super(_Database());
  UserProfile? value = const UserProfile(
      name: 'Ada', occupation: 'Designer', tone: 'calm');
  bool failLoad = false;
  bool failSave = false;
  bool ignoreSave = false;
  int reads = 0;
  int writes = 0;

  @override
  Future<UserProfile?> get() async {
    reads++;
    if (failLoad) throw StateError('Profile read unavailable');
    return value;
  }

  @override
  Future<void> save(UserProfile profile) async {
    writes++;
    if (failSave) throw StateError('Profile write unavailable');
    if (!ignoreSave) value = profile;
  }
}

Future<void> _open(WidgetTester tester, _Memories memory, _Profiles profile,
    {double scale = 1, int refreshToken = 0}) async {
  await tester.pumpWidget(MaterialApp(
    theme: AppTheme.dark,
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(scale)),
      child: Scaffold(body: MemoriesPage(memory: memory, profile: profile, refreshToken: refreshToken)),
    ),
  ));
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _openEditor(WidgetTester tester, _Profiles profile,
    void Function(bool) onResult) async {
  await tester.pumpWidget(MaterialApp(
    theme: AppTheme.dark,
    home: Scaffold(body: Builder(builder: (context) => TextButton(
      onPressed: () async => onResult(await showProfileEditor(context, profile)),
      child: const Text('Open editor'),
    ))),
  ));
  await _tap(tester, find.text('Open editor'));
}

void main() {
  for (final failure in ['write', 'readback', 'unchanged profile']) {
    testWidgets('profile $failure failure does not report success to the caller',
        (tester) async {
      final profile = _Profiles();
      bool? result;
      await _openEditor(tester, profile, (value) => result = value);
      await tester.enterText(find.byKey(const Key('profile-name')), 'Grace');
      profile.failSave = failure == 'write';
      profile.failLoad = failure == 'readback';
      profile.ignoreSave = failure == 'unchanged profile';
      await _tap(tester, find.text('Save profile'));
      expect(result, isNull);
      expect(find.text(failure == 'write'
          ? 'Profile was not saved. Please try again.'
          : 'Could not confirm saved profile. Please try again.'), findsOneWidget);
      profile.failSave = false;
      profile.failLoad = false;
      profile.ignoreSave = false;
      await _tap(tester, find.text('Save profile'));
      expect(result, isTrue);
      expect(profile.value!.name, 'Grace');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('profile editor validates a name and saves optional occupation and tone',
      (tester) async {
    final profile = _Profiles();
    await _open(tester, _Memories(), profile);
    expect(find.text('Edit profile'), findsOneWidget);
    await _tap(tester, find.text('Edit profile'));
    expect(tester.widget<TextFormField>(find.byKey(const Key('profile-name'))).controller!.text, 'Ada');
    await tester.enterText(find.byKey(const Key('profile-name')), '   ');
    await _tap(tester, find.text('Save profile'));
    expect(find.text('Enter your name'), findsOneWidget);
    expect(profile.writes, 0);
    await tester.enterText(find.byKey(const Key('profile-name')), '  Grace  ');
    await tester.enterText(find.byKey(const Key('profile-occupation')), '');
    for (final tone in ['Cheerful', 'Mature', 'Playful', 'Calm', 'Professional']) {
      expect(find.widgetWithText(ChoiceChip, tone), findsOneWidget);
    }
    await _tap(tester, find.widgetWithText(ChoiceChip, 'Professional'));
    await _tap(tester, find.text('Save profile'));
    expect(profile.value!.name, 'Grace');
    expect(profile.value!.occupation, '');
    expect(profile.value!.tone, 'professional');
    expect(profile.writes, 1);
    expect(profile.reads, 4);
    expect(find.text('Grace'), findsOneWidget);
    expect(find.text('Professional'), findsOneWidget);
    await _tap(tester, find.text('Edit tone'));
    await _tap(tester, find.text('Cancel'));
    expect(profile.writes, 1);
  });

  for (final failure in ['write', 'readback', 'unchanged row']) {
    testWidgets('delete $failure failure never optimistically removes a row',
        (tester) async {
      final memories = _Memories([_memory(7, 'I like tea.')]);
      await _open(tester, memories, _Profiles());
      memories.failDelete = failure == 'write';
      memories.failLoad = failure == 'readback';
      memories.ignoreDelete = failure == 'unchanged row';
      await _tap(tester, find.byKey(const Key('delete-memory-7')));
      await _tap(tester, find.widgetWithText(FilledButton, 'Delete'));
      expect(find.text('I like tea.'), findsOneWidget);
      expect(find.text(failure == 'write'
          ? 'Memory could not be deleted. Please try again.'
          : 'Could not confirm deletion. Refresh to check saved data.'), findsOneWidget);
      memories.failLoad = false;
      await _tap(tester, find.byTooltip('Refresh context'));
      expect(find.textContaining('could not be deleted'), findsNothing);
      expect(find.textContaining('Could not confirm deletion'), findsNothing);
      expect(find.text('I like tea.'), failure == 'readback' ? findsNothing : findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('delete requires confirmation and reads back the remaining rows',
      (tester) async {
    final memories = _Memories([_memory(7, 'I like tea.')]);
    await _open(tester, memories, _Profiles());
    final delete = find.byKey(const Key('delete-memory-7'));
    expect(delete, findsOneWidget);
    await _tap(tester, delete);
    expect(find.text('Delete this memory?'), findsOneWidget);
    await _tap(tester, find.text('Keep memory'));
    expect(memories.rows, hasLength(1));
    await _tap(tester, delete);
    await _tap(tester, find.widgetWithText(FilledButton, 'Delete'));
    expect(memories.rows, isEmpty);
    expect(find.text('No memories yet'), findsOneWidget);
    expect(find.text('I like tea.'), findsNothing);
    expect(memories.reads, 2);
  });

  for (final failure in ['write', 'readback', 'missing row']) {
    testWidgets('add $failure failure keeps the sheet honest and recoverable',
        (tester) async {
      final memories = _Memories();
      await _open(tester, memories, _Profiles());
      await _tap(tester, find.text('Add memory'));
      await tester.enterText(find.byKey(const Key('memory-content')), 'I like tea.');
      memories.failAdd = failure == 'write';
      memories.failLoad = failure == 'readback';
      memories.ignoreAdd = failure == 'missing row';
      await _tap(tester, find.text('Save memory'));
      expect(find.text(failure == 'write'
          ? 'Memory was not saved. Please try again.'
          : 'Could not confirm saved memory. Refresh before adding it again.'), findsOneWidget);
      expect(find.text('Save memory'), findsOneWidget);
      if (failure == 'write') {
        expect(memories.rows, isEmpty);
        memories.failAdd = false;
        await _tap(tester, find.text('Save memory'));
        expect(find.text('I like tea.'), findsOneWidget);
      } else {
        await _tap(tester, find.text('Cancel'));
        expect(find.text('0 saved memories'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('add memory validates content and category then reads saved rows',
      (tester) async {
    final memories = _Memories();
    await _open(tester, memories, _Profiles());
    expect(find.text('Add memory'), findsOneWidget);
    await _tap(tester, find.text('Add memory'));
    await _tap(tester, find.text('Save memory'));
    expect(find.text('Enter a memory'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('memory-content')), '  I prefer tea.  ');
    await tester.enterText(find.byKey(const Key('memory-category')), '  ');
    await _tap(tester, find.text('Save memory'));
    expect(find.text('Enter a category'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('memory-category')), 'preference');
    await _tap(tester, find.text('Save memory'));
    expect(find.text('Save memory'), findsNothing);
    expect(find.text('I prefer tea.'), findsOneWidget);
    expect(find.text('1 saved memory'), findsOneWidget);
    expect(memories.rows.single.content, 'I prefer tea.');
    expect(memories.rows.single.category, 'preference');
    expect(memories.reads, 2);
  });

  testWidgets('refresh token reloads memories and the externally edited profile',
      (tester) async {
    final memories = _Memories();
    final profile = _Profiles();
    await _open(tester, memories, profile);
    profile.value = const UserProfile(name: 'Grace', tone: 'mature');
    memories.rows.add(_memory(1, 'I work in research.'));
    await _open(tester, memories, profile);
    expect(memories.reads, 1);
    await _open(tester, memories, profile, refreshToken: 1);
    expect(memories.reads, 2);
    expect(find.text('Grace'), findsOneWidget);
    expect(find.text('Mature'), findsOneWidget);
    expect(find.text('I work in research.'), findsOneWidget);
  });

  for (final source in ['memories', 'profile']) {
    testWidgets('$source load failure shows retry instead of invented data',
        (tester) async {
      final memories = _Memories()..failLoad = source == 'memories';
      final profile = _Profiles()..failLoad = source == 'profile';
      await _open(tester, memories, profile);
      expect(find.text('Could not load context'), findsOneWidget);
      expect(find.text('0 saved memories'), findsNothing);
      memories.failLoad = false;
      profile.failLoad = false;
      await _tap(tester, find.text('Retry'));
      expect(find.text('No memories yet'), findsOneWidget);
      expect(find.text('Ada'), findsOneWidget);
      memories.rows.add(_memory(1, 'A real newly saved memory.'));
      await _tap(tester, find.byTooltip('Refresh context'));
      expect(find.text('A real newly saved memory.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('search and category filters are local and reversible',
      (tester) async {
    final memories = _Memories([
      _memory(1, 'I prefer quiet mornings.', 'preference'),
      _memory(2, 'The workshop opens on Friday.', 'fact'),
      _memory(3, 'A quiet studio opens soon.', 'fact'),
    ]);
    await _open(tester, memories, _Profiles());
    final search = find.byKey(const Key('memory-search'));
    await tester.ensureVisible(search);
    await tester.enterText(search, 'QUIET');
    await tester.pumpAndSettle();
    expect(find.text('I prefer quiet mornings.'), findsOneWidget);
    expect(find.text('The workshop opens on Friday.'), findsNothing);
    await _tap(tester, find.widgetWithText(ChoiceChip, 'Fact'));
    expect(find.text('I prefer quiet mornings.'), findsNothing);
    expect(find.text('A quiet studio opens soon.'), findsOneWidget);
    await tester.enterText(search, 'no matching content');
    await tester.pumpAndSettle();
    expect(find.text('No matching memories'), findsOneWidget);
    expect(find.text('3 saved memories'), findsOneWidget);
    await _tap(tester, find.text('Clear filters'));
    expect(find.text('I prefer quiet mornings.'), findsOneWidget);
    expect(find.text('The workshop opens on Friday.'), findsOneWidget);
    expect(memories.reads, 1);
    expect(memories.searchCalls, 0);
  });

  testWidgets('renders repository memories and truthful local context',
      (tester) async {
    final memories = _Memories([
      _memory(1, 'I prefer quiet mornings.', 'preference'),
      _memory(2, 'The workshop opens on Friday.', 'fact'),
    ]);
    await _open(tester, memories, _Profiles());
    expect(find.text('Context & memory'), findsOneWidget);
    expect(find.text('On this device'), findsOneWidget);
    expect(find.text('Ada'), findsOneWidget);
    expect(find.text('Designer'), findsOneWidget);
    expect(find.text('Calm'), findsOneWidget);
    expect(find.text('2 saved memories'), findsOneWidget);
    expect(find.text('I prefer quiet mornings.'), findsOneWidget);
    expect(find.text('The workshop opens on Friday.'), findsOneWidget);
    expect(find.textContaining('Mem0 is not connected'), findsOneWidget);
    expect(find.textContaining('during the conversation'), findsOneWidget);
    expect(find.textContaining('encrypted'), findsNothing);
    expect(memories.searchCalls, 0);
  });
}
