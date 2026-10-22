// Deleting saved shots, kept apart from the screen so it can be tested on a computer.

import 'dart:io';

/// Deletes [files] and returns how many were there. With [all], it also deletes index.csv in
/// [root], the list of every recording, because the whole history goes.
Future<int> deleteRecordings(Directory root, Iterable<File> files, {bool all = false}) async {
  var deleted = 0;
  for (final file in files) {
    if (await file.exists()) {
      await file.delete();
      deleted++;
    }
  }
  if (all) {
    final index = File('${root.path}/index.csv');
    if (await index.exists()) await index.delete();
  }
  return deleted;
}
