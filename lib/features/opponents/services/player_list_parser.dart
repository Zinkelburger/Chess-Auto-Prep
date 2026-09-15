/// Pasted player lists: organizer tables, spreadsheets, markdown, and the
/// app's own opponent JSON. Anything tabular with a `Name` heading becomes
/// an [OpponentList]; JSON is handed straight to [OpponentList.parse].
library;

import 'dart:convert';

import 'package:csv/csv.dart';

import '../../../services/opponent_list.dart';

/// Column headings, lower-cased with everything but letters removed, that
/// feed each opponent field.
const _nameHeadings = ['name', 'player'];
const _uscfIdHeadings = ['uscfid', 'uscf', 'uschessid'];
const _ratingHeadings = ['rating', 'rtg'];
const _chesscomHeadings = ['chesscom', 'chesscomaccounts'];
const _lichessHeadings = ['lichess', 'lichessaccounts'];

final _lineBreak = RegExp(r'\r?\n');
final _pipeEdges = RegExp(r'^\s*\||\|\s*$');
final _wideGap = RegExp(r'\s{2,}');
final _nonLetters = RegExp(r'[^a-z]');

/// A markdown table's separator row (`| --- | :-: |`).
final _markdownRule = RegExp(r'^[\s|:\-]+$');

/// `[visible](url)` → `visible`.
final _markdownLink = RegExp(r'\[([^\]]+)\]\([^)]*\)');

/// Organizer tables, spreadsheets, and the existing opponent JSON format.
OpponentList parsePlayerList(String text) {
  final input = text.trim();
  if (input.startsWith('{') || input.startsWith('[')) {
    return OpponentList.parse(input, keepAccountless: true);
  }
  final lines = input
      .split(_lineBreak)
      .where((l) => l.trim().isNotEmpty)
      .toList();
  if (lines.isEmpty) {
    throw const FormatException('Paste a table with Name and USCF ID columns.');
  }
  final headerIndex = lines.indexWhere(
    (l) => _cells(l).any((c) => c.trim().toLowerCase() == 'name'),
  );
  if (headerIndex < 0) {
    throw const FormatException(
      'Include the column headings, such as Name, Rating, USCF ID.',
    );
  }
  final columns = _cells(
    lines[headerIndex],
  ).map((s) => s.toLowerCase().replaceAll(_nonLetters, '')).toList();
  final rows = <Map<String, Object?>>[];
  for (final line in lines.skip(headerIndex + 1)) {
    if (_markdownRule.hasMatch(line)) continue;
    final row = _TableRow(columns, _cells(line));
    final name = row[_nameHeadings];
    if (name == null || name.isEmpty) continue;
    rows.add({
      'name': name,
      'uscf_id': row[_uscfIdHeadings],
      'rating': row[_ratingHeadings],
      'chesscom': row[_chesscomHeadings],
      'lichess': row[_lichessHeadings],
    });
  }
  if (rows.isEmpty) throw const FormatException('No player rows found.');
  return OpponentList.parse(jsonEncode(rows), keepAccountless: true);
}

/// Splits one line on whichever delimiter it uses: tabs, pipes, commas
/// (proper CSV), or runs of two or more spaces.
List<String> _cells(String line) {
  if (line.contains('\t')) return line.split('\t');
  if (line.contains('|')) return line.replaceAll(_pipeEdges, '').split('|');
  if (line.contains(',')) {
    return Csv().decode(line).first.map((v) => v.toString()).toList();
  }
  return line.trim().split(_wideGap);
}

/// One data row addressed by heading alias.
class _TableRow {
  const _TableRow(this.columns, this.values);

  final List<String> columns;
  final List<String> values;

  /// The trimmed cell under the first of [headings] present, with any
  /// markdown link reduced to its text; null when the column is absent or
  /// the row is short.
  String? operator [](List<String> headings) {
    final i = columns.indexWhere(headings.contains);
    if (i < 0 || i >= values.length) return null;
    return values[i].replaceAllMapped(_markdownLink, (m) => m[1]!).trim();
  }
}

/// Table cells only: links remain their visible text, including USCF IDs.
String playerTableTextFromHtml(String html) {
  final rows = <String>[];
  for (final row in _htmlRow.allMatches(html)) {
    final cells = _htmlCell
        .allMatches(row[1]!)
        .map((m) => _stripHtml(m[1]!))
        .toList();
    if (cells.isNotEmpty) rows.add(cells.join('\t'));
  }
  return rows.join('\n');
}

final _htmlRow = RegExp(r'<tr\b[^>]*>([\s\S]*?)</tr>', caseSensitive: false);
final _htmlCell = RegExp(
  r'<t[dh]\b[^>]*>([\s\S]*?)</t[dh]>',
  caseSensitive: false,
);
final _htmlTag = RegExp(r'<[^>]*>');

String _stripHtml(String s) => s
    .replaceAll(_htmlTag, '')
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&amp;', '&')
    .replaceAll('&#39;', "'")
    .replaceAll('&quot;', '"')
    .trim();
