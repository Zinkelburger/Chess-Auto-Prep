/// US Chess ratings API, for the two lookups the opponent editor needs: an ID
/// to a name and ratings, and a name to candidate IDs.
///
/// Same public endpoint the MCP server's `uscf.py` uses
/// (`ratings-api.uschess.org/api/v1`), unauthenticated, so calls are spaced
/// out: a field of forty looked up in a loop must not read as a scrape.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

const _kApi = 'https://ratings-api.uschess.org/api/v1';
const _kUserAgent = 'chess-auto-prep/1.0 (tournament prep tool)';
const _kSpacing = Duration(milliseconds: 700);

class UscfException implements Exception {
  UscfException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// One member as the API describes them. Ratings are null when the member
/// has none in that system.
class UscfMember {
  const UscfMember({
    required this.id,
    required this.name,
    this.state,
    this.regular,
    this.quick,
    this.blitz,
    this.onlineRegular,
    this.fideTitle,
    this.status,
  });

  final String id;

  /// `Hikaru Nakamura`, from the API's upper-case first and last names.
  final String name;
  final String? state;
  final int? regular;
  final int? quick;
  final int? blitz;
  final int? onlineRegular;
  final String? fideTitle;
  final String? status;

  /// The rating a tournament pairs on.
  int? get rating => regular;

  /// `2846 · NY · Active`, whichever parts exist.
  String get summary => [
    if (regular != null) '$regular',
    if (state != null && state!.isNotEmpty) state!,
    if (status != null && status!.isNotEmpty) status!,
  ].join(' · ');

  factory UscfMember.fromJson(Map<String, dynamic> json) {
    int? ratingOf(String system) {
      for (final entry in (json['ratings'] as List?) ?? const []) {
        if (entry is Map && entry['ratingSystem'] == system) {
          return (entry['rating'] as num?)?.toInt();
        }
      }
      return null;
    }

    final first = (json['firstName'] as String? ?? '').trim();
    final last = (json['lastName'] as String? ?? '').trim();
    return UscfMember(
      id: (json['id'] ?? '').toString(),
      name: titleCaseName([first, last].where((s) => s.isNotEmpty).join(' ')),
      state: json['stateRep'] as String? ?? json['jurisdiction'] as String?,
      regular: ratingOf('R'),
      quick: ratingOf('Q'),
      blitz: ratingOf('B'),
      onlineRegular: ratingOf('OR'),
      fideTitle: json['fideTitle'] as String?,
      status: json['status'] as String?,
    );
  }
}

/// `HIKARU NAKAMURA` → `Hikaru Nakamura`; keeps a capital after an
/// apostrophe or hyphen (`O'BRIEN`, `SMITH-JONES`).
String titleCaseName(String raw) {
  final buffer = StringBuffer();
  var capitalizeNext = true;
  for (final rune in raw.runes) {
    final ch = String.fromCharCode(rune);
    if (ch == ' ' || ch == '-' || ch == "'" || ch == '.') {
      buffer.write(ch);
      capitalizeNext = true;
      continue;
    }
    buffer.write(capitalizeNext ? ch.toUpperCase() : ch.toLowerCase());
    capitalizeNext = false;
  }
  return buffer.toString();
}

class UscfClient {
  UscfClient({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  DateTime? _lastRequest;

  void close() => _client.close();

  Future<Map<String, dynamic>> _get(String path) async {
    final last = _lastRequest;
    if (last != null) {
      final wait = _kSpacing - DateTime.now().difference(last);
      if (wait > Duration.zero) await Future<void>.delayed(wait);
    }
    _lastRequest = DateTime.now();
    final http.Response response;
    try {
      response = await _client
          .get(Uri.parse('$_kApi$path'), headers: {'User-Agent': _kUserAgent})
          .timeout(const Duration(seconds: 20));
    } catch (e) {
      throw UscfException('Could not reach US Chess ($e).');
    }
    if (response.statusCode == 404) {
      throw UscfException('US Chess has no member with that ID.');
    }
    if (response.statusCode != 200) {
      throw UscfException('US Chess answered HTTP ${response.statusCode}.');
    }
    try {
      return (jsonDecode(response.body) as Map).cast<String, dynamic>();
    } catch (_) {
      throw UscfException('US Chess returned something unreadable.');
    }
  }

  /// The member with this ID.
  Future<UscfMember> member(String uscfId) async {
    final id = uscfId.replaceAll(RegExp(r'[^0-9]'), '');
    if (id.length < 7 || id.length > 9) {
      throw UscfException('A US Chess ID is 7 to 9 digits.');
    }
    return UscfMember.fromJson(
      await _get('/members/${Uri.encodeComponent(id)}'),
    );
  }

  /// Members whose name matches [name], best matches first as the API
  /// orders them.
  Future<List<UscfMember>> search(String name) async {
    final q = name.trim();
    if (q.length < 2) return const [];
    final data = await _get('/members?name=${Uri.encodeQueryComponent(q)}');
    return [
      for (final item in (data['items'] as List?) ?? const [])
        if (item is Map) UscfMember.fromJson(item.cast<String, dynamic>()),
    ];
  }
}
