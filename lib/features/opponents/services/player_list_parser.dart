import 'dart:convert';

import 'package:csv/csv.dart';

import '../../../services/opponent_list.dart';

/// Organizer tables, spreadsheets, and the existing opponent JSON format.
OpponentList parsePlayerList(String text) {
  final input = text.trim();
  if (input.startsWith('{') || input.startsWith('[')) {
    return OpponentList.parse(input, keepAccountless: true);
  }
  final lines = input
      .split(RegExp(r'\r?\n'))
      .where((l) => l.trim().isNotEmpty)
      .toList();
  if (lines.isEmpty) {
    throw const FormatException('Paste a table with Name and USCF ID columns.');
  }
  List<String> cells(String line) {
    if (line.contains('\t')) return line.split('\t');
    if (line.contains('|')) {
      return line.replaceAll(RegExp(r'^\s*\||\|\s*$'), '').split('|');
    }
    if (line.contains(',')) {
      return Csv().decode(line).first.map((v) => v.toString()).toList();
    }
    return line.trim().split(RegExp(r'\s{2,}'));
  }

  final headerIndex = lines.indexWhere(
    (l) => cells(l).any((c) => c.trim().toLowerCase() == 'name'),
  );
  if (headerIndex < 0) {
    throw const FormatException(
      'Include the column headings, such as Name, Rating, USCF ID.',
    );
  }
  final headers = cells(
    lines[headerIndex],
  ).map((s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '')).toList();
  final rows = <Map<String, Object?>>[];
  for (final line in lines.skip(headerIndex + 1)) {
    if (RegExp(r'^[\s|:\-]+$').hasMatch(line)) continue;
    final values = cells(line);
    String? value(List<String> names) {
      final i = headers.indexWhere(names.contains);
      if (i < 0 || i >= values.length) return null;
      return values[i]
          .replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]*\)'), (m) => m[1]!)
          .trim();
    }

    final name = value(['name', 'player']);
    if (name == null || name.isEmpty) continue;
    rows.add({
      'name': name,
      'uscf_id': value(['uscfid', 'uscf', 'uschessid']),
      'rating': value(['rating', 'rtg']),
      'chesscom': value(['chesscom', 'chesscomaccounts']),
      'lichess': value(['lichess', 'lichessaccounts']),
    });
  }
  if (rows.isEmpty) throw const FormatException('No player rows found.');
  return OpponentList.parse(jsonEncode(rows), keepAccountless: true);
}

/// Table cells only: links remain their visible text, including USCF IDs.
String playerTableTextFromHtml(String html) {
  String clean(String s) => s
      .replaceAll(RegExp(r'<[^>]*>'), '')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&#39;', "'")
      .replaceAll('&quot;', '"')
      .trim();
  final rows = <String>[];
  for (final row in RegExp(
    r'<tr\b[^>]*>([\s\S]*?)</tr>',
    caseSensitive: false,
  ).allMatches(html)) {
    final cells = RegExp(
      r'<t[dh]\b[^>]*>([\s\S]*?)</t[dh]>',
      caseSensitive: false,
    ).allMatches(row[1]!).map((m) => clean(m[1]!)).toList();
    if (cells.isNotEmpty) rows.add(cells.join('\t'));
  }
  return rows.join('\n');
}
