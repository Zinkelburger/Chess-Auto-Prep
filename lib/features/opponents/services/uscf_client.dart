/// US Chess ratings API, for the two lookups the opponent editor needs: an ID
/// to a name and ratings, and a name to candidate IDs.
///
/// Same public endpoint the MCP server's `uscf.py` uses
/// (`ratings-api.uschess.org/api/v1`), unauthenticated, so calls are spaced
/// out: a field of forty looked up in a loop must not read as a scrape.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

const _apiRoot = 'https://ratings-api.uschess.org/api/v1';
const _userAgent = 'chess-auto-prep/1.0 (tournament prep tool)';

/// Minimum gap between two requests from one client.
const _requestSpacing = Duration(milliseconds: 700);
const _requestTimeout = Duration(seconds: 20);

/// US Chess IDs are 7 to 9 digits.
const _minIdDigits = 7;
const _maxIdDigits = 9;

/// Shortest name the search endpoint is asked about.
const _minSearchLength = 2;

/// The API's rating-system codes.
const _regularSystem = 'R';
const _quickSystem = 'Q';
const _blitzSystem = 'B';
const _onlineRegularSystem = 'OR';

/// A lookup that did not produce a member, worded for the user.
class UscfException implements Exception {
  const UscfException(this.message);
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
    if (state case final state? when state.isNotEmpty) state,
    if (status case final status? when status.isNotEmpty) status,
  ].join(' · ');

  factory UscfMember.fromJson(Map<String, dynamic> json) {
    final ratings = _ratingsBySystem(json['ratings']);
    final first = (json['firstName'] as String? ?? '').trim();
    final last = (json['lastName'] as String? ?? '').trim();
    return UscfMember(
      id: (json['id'] ?? '').toString(),
      name: titleCaseName([first, last].where((s) => s.isNotEmpty).join(' ')),
      state: json['stateRep'] as String? ?? json['jurisdiction'] as String?,
      regular: ratings[_regularSystem],
      quick: ratings[_quickSystem],
      blitz: ratings[_blitzSystem],
      onlineRegular: ratings[_onlineRegularSystem],
      fideTitle: json['fideTitle'] as String?,
      status: json['status'] as String?,
    );
  }

  /// The `ratings` list as system code → rating; the first entry per system
  /// wins, and a system listed without a rating maps to null.
  static Map<String, int?> _ratingsBySystem(Object? ratings) {
    final bySystem = <String, int?>{};
    for (final entry in (ratings as List?) ?? const []) {
      if (entry case {'ratingSystem': final String system}) {
        bySystem.putIfAbsent(system, () => (entry['rating'] as num?)?.toInt());
      }
    }
    return bySystem;
  }
}

/// `HIKARU NAKAMURA` → `Hikaru Nakamura`; keeps a capital after an
/// apostrophe or hyphen (`O'BRIEN`, `SMITH-JONES`).
String titleCaseName(String raw) {
  const wordBreaks = {' ', '-', "'", '.'};
  final buffer = StringBuffer();
  var capitalizeNext = true;
  for (final rune in raw.runes) {
    final ch = String.fromCharCode(rune);
    if (wordBreaks.contains(ch)) {
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

  /// The member with this ID.
  Future<UscfMember> member(String uscfId) async {
    final id = uscfId.replaceAll(RegExp(r'[^0-9]'), '');
    if (id.length < _minIdDigits || id.length > _maxIdDigits) {
      throw const UscfException('A US Chess ID is 7 to 9 digits.');
    }
    return UscfMember.fromJson(
      await _get('/members/${Uri.encodeComponent(id)}'),
    );
  }

  /// Members whose name matches [name], best matches first as the API
  /// orders them.
  Future<List<UscfMember>> search(String name) async {
    final query = name.trim();
    if (query.length < _minSearchLength) return const [];
    final data = await _get('/members?name=${Uri.encodeQueryComponent(query)}');
    return [
      for (final item in (data['items'] as List?) ?? const [])
        if (item is Map) UscfMember.fromJson(item.cast<String, dynamic>()),
    ];
  }

  Future<Map<String, dynamic>> _get(String path) async {
    await _spaceOutRequests();
    final response = await _send(path);
    return switch (response.statusCode) {
      200 => _decodeObject(response.body),
      404 => throw const UscfException('US Chess has no member with that ID.'),
      final code => throw UscfException('US Chess answered HTTP $code.'),
    };
  }

  /// Waits until [_requestSpacing] has passed since the previous request.
  Future<void> _spaceOutRequests() async {
    final last = _lastRequest;
    if (last != null) {
      final wait = _requestSpacing - DateTime.now().difference(last);
      if (wait > Duration.zero) await Future<void>.delayed(wait);
    }
    _lastRequest = DateTime.now();
  }

  Future<http.Response> _send(String path) async {
    try {
      return await _client
          .get(Uri.parse('$_apiRoot$path'), headers: {'User-Agent': _userAgent})
          .timeout(_requestTimeout);
    } catch (e) {
      throw UscfException('Could not reach US Chess ($e).');
    }
  }

  static Map<String, dynamic> _decodeObject(String body) {
    try {
      return (jsonDecode(body) as Map).cast<String, dynamic>();
    } catch (_) {
      throw const UscfException('US Chess returned something unreadable.');
    }
  }
}
