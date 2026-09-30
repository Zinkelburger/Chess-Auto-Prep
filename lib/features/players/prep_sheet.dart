import 'package:path/path.dart' as p;

import '../../chess/players/player.dart';
import '../../chess/pgn/chapter.dart';
import '../../chess/pgn/move_text.dart';
import '../../chess/pgn/study.dart';
import '../../storage/chapter_files.dart';
import '../../storage/pgn_document_store.dart';

/// A portable event sheet, including the actual preparation, not file links.
Future<String> prepSheet(
  PlayerGroup group,
  List<Player> players,
  PgnDocumentStore documents,
) async {
  final people = players.where((e) => group.contains(e.id)).toList();
  final text = StringBuffer('# ${group.name}\n\n');
  text.writeln(
    [
      if (group.fields['date'] != null) group.fields['date'],
      if (group.fields['rounds'] != null) '${group.fields['rounds']} rounds',
      '${people.length} players',
      '${people.where((e) => group.prepared(e.id)).length} prepared',
    ].join(' · '),
  );
  text.writeln('\n| Player | Rating | US Chess | Accounts | Prepared |');
  text.writeln('| --- | --- | --- | --- | --- |');
  for (final person in people) {
    text.writeln(
      '| ${_cell(person.name)} | ${person.text('rating')} | ${person.text('uscf_id')} | ${_cell(person.accounts.map((a) => '${a.site.label}: ${a.username}').join(', '))} | ${group.prepared(person.id) ? 'Yes' : 'No'} |',
    );
  }
  for (final player in people) {
    text.writeln('\n## ${player.name}\n\n${player.text('notes')}');
    final file = player.text('prep_file');
    if (file.isEmpty) continue;
    final read = await documents.open(ChapterRef.at(file));
    if (read is! Opened) {
      // One missing study never costs the rest of the sheet.
      text.writeln(
        read is Absent
            ? '\n(prep study not found: ${p.basename(file)})'
            : '\n(prep study could not be read: ${p.basename(file)})',
      );
      continue;
    }
    final parsed = await readChapter(name: player.name, text: read.text);
    for (final chapter in studyChapters(parsed.lines)) {
      final tree = parsed.lines[chapter.index].tree;
      text.writeln('\n### ${chapter.name}\n');
      text.writeln(
        tree == null || tree.isEmpty
            ? '(no moves yet)'
            : writeMoveText(tree, terminator: '*'),
      );
    }
  }
  return '$text';
}

String _cell(String text) =>
    text.replaceAll('|', r'\|').replaceAll('\n', '<br>');
