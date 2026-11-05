import 'dart:math';

import 'package:assistant/data/repos.dart';
import 'package:sqflite/sqflite.dart';

const memoryBenchSizes = [1000, 5000, 20000];

/// Stable labelled facts occur in every corpus, before seeded background data.
const memoryBenchFacts = [
  'I prefer jasmine tea without sugar',
  'I live in Indiranagar Bengaluru',
  'I work as a marine biologist',
  'I prefer meetings at 10 am on Tuesdays',
  'I prefer concise answers with bullet points',
  'My sister Priya lives in Pune',
  'My brother Arjun works in robotics',
  'My mother Meera likes orchids',
  'My father Ravi loves astronomy',
  'Nisha lives in Jaipur',
  'I like watercolor painting on weekends',
  'I love birdwatching near Ulsoor lake',
  'I like playing badminton on Saturdays',
  'I love baking sourdough bread',
  'I like collecting vintage postcards',
  'I am attending the Kyoto ceramics workshop on 2027-02-14',
  'I have a dentist appointment on 2027-03-09',
  'I am starting a pottery course on 2027-04-12',
  'I have a passport renewal appointment on 2027-05-18',
  'I am visiting the Mysuru museum on 2027-06-21',
  'Archive note: the cobalt compass is in drawer seven',
  'Archive note: the amber notebook has grid pages',
  'Archive note: the silver lantern uses rechargeable batteries',
  'Archive note: the velvet cushion has a triangular pattern',
  'Archive note: the copper kettle holds two litres',
];

/// Inserts exactly [size] distinct rows through the production add path.
/// Batches are transactions, rather than concurrent calls on one connection.
Future<Map<int, String>> seedMemoryCorpus(
  MemoryRepo repo, {
  required int size,
  int batchSize = 250,
}) async {
  if (!memoryBenchSizes.contains(size) || batchSize <= 0) {
    throw ArgumentError('Use a supported corpus size and positive batch size');
  }
  final db = repo.db;
  if (db is! Database) {
    throw ArgumentError('Seeding requires a database outside a transaction');
  }
  final random = Random(8426);
  const cities = ['Kochi', 'Surat', 'Nagpur', 'Bhopal', 'Chennai'];
  const hobbies = ['cycling', 'knitting', 'chess', 'gardening', 'origami'];
  const objects = ['folder', 'ticket', 'bottle', 'pencil', 'basket'];
  final inserted = <int, String>{};
  for (var start = 0; start < size; start += batchSize) {
    final end = min(start + batchSize, size);
    await db.transaction((tx) async {
      final batchRepo = MemoryRepo(tx);
      for (var i = start; i < end; i++) {
        final String content;
        if (i < memoryBenchFacts.length) {
          content = memoryBenchFacts[i];
        } else {
          final city = cities[random.nextInt(cities.length)];
          final hobby = hobbies[random.nextInt(hobbies.length)];
          final object = objects[random.nextInt(objects.length)];
          final day = 1 + random.nextInt(28);
          content = switch (i % 4) {
            0 => 'Contact record $i: colleague Dev$i lives in $city',
            1 => 'Hobby record $i: club member enjoys $hobby in $city',
            2 => 'Dated record $i: $city exhibition on 2028-08-'
                '${day.toString().padLeft(2, '0')}',
            _ => 'Noise record $i: $object inventory code '
                '${random.nextInt(1000000)}',
          };
        }
        final id = await batchRepo.add(content,
            category: const [0, 3, 4].contains(i) ? 'preference' : 'fact',
            importance: i < memoryBenchFacts.length
                ? 0.9
                : 0.1 + random.nextDouble() * 0.6,
            source: 'memory-benchmark');
        inserted[id] = content;
      }
    });
  }
  return inserted;
}
