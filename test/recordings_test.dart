import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sswingg_recorder/recordings.dart';

void main() {
  late Directory root;
  late File pull, cover, index;

  setUp(() {
    root = Directory.systemTemp.createTempSync('recordings_test');
    Directory('${root.path}/pull_shot').createSync();
    Directory('${root.path}/cover_drive').createSync();
    pull = File('${root.path}/pull_shot/pull_shot_001.csv')..writeAsStringSync('a');
    cover = File('${root.path}/cover_drive/cover_drive_001.csv')..writeAsStringSync('b');
    index = File('${root.path}/index.csv')..writeAsStringSync('file\r\n');
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('deletes only the chosen shots and keeps index.csv', () async {
    expect(await deleteRecordings(root, [pull]), 1);
    expect(pull.existsSync(), isFalse);
    expect(cover.existsSync(), isTrue);
    expect(index.existsSync(), isTrue);
  });

  test('deleting all shots also deletes index.csv', () async {
    expect(await deleteRecordings(root, [pull, cover], all: true), 2);
    expect(pull.existsSync() || cover.existsSync() || index.existsSync(), isFalse);
  });

  test('a file already gone is not counted', () async {
    pull.deleteSync();
    expect(await deleteRecordings(root, [pull, cover]), 1);
  });
}
