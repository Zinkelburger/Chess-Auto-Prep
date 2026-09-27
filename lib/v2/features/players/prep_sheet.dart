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
  final people = players.where((p) => group.contains(p.id)).toList();
  final text = StringBuffer('# ${group.name}\n\n');
  text.writeln(
    [
      if (group.fields['date'] != null) group.fields['date'],
      if (group.fields['rounds'] != null) '${group.fields['rounds']} rounds',
      '${people.length} players',
      '${people.where((p) => group.prepared(p.id)).length} prepared',
    ].join(' · '),
  );
  text.writeln('\n| Player | Rating | US Chess | Accounts | Prepared |');
  text.writeln('| --- | --- | --- | --- | --- |');
  for (final p in people) {
    text.writeln(
      '| ${_cell(p.name)} | ${p.text('rating')} | ${p.text('uscf_id')} | ${_cell(p.accounts.map((a) => '${a.site.label}: ${a.username}').join(', '))} | ${group.prepared(p.id) ? 'Yes' : 'No'} |',
    );
  }
  for (final player in people) {
    text.writeln('\n## ${player.name}\n\n${player.text('notes')}');
    if (player.text('prep_file').isEmpty) continue;
    final read = await documents.open(ChapterRef.at(player.text('prep_file')));
    if (read is! Opened)
      throw StateError('Could not read ${player.name}’s prep study.');
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
