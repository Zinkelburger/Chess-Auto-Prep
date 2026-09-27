import 'dart:convert';

import 'package:http/http.dart' as http;

import 'lichess_http.dart';

typedef PlayerRating = ({String name, int? rating});

/// The public US Chess member endpoint. UI receives a result, never a client.
final class PlayerRatings {
  PlayerRatings(this.client);
  final http.Client client;
  DateTime? _last;
  Future<PlayerRating> lookup(String id) async {
    if (!RegExp(r'^\d{7,9}$').hasMatch(id))
      throw const FormatException('A US Chess ID is 7 to 9 digits.');
    final last = _last;
    if (last != null) {
      final wait =
          const Duration(milliseconds: 700) - DateTime.now().difference(last);
      if (wait > Duration.zero) await Future<void>.delayed(wait);
    }
    _last = DateTime.now();
    final response = await client
        .get(
          Uri.https('ratings-api.uschess.org', '/api/v1/members/$id'),
          headers: {'User-Agent': appUserAgent},
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode == 404)
      throw const FormatException('US Chess has no member with that ID.');
    if (response.statusCode != 200)
      throw StateError(
        'US Chess answered HTTP ${response.statusCode}. Try again later.',
      );
    final data = jsonDecode(response.body) as Map;
    final name = '${data['firstName'] ?? ''} ${data['lastName'] ?? ''}'.trim();
    final ratings = data['ratings'] as List? ?? const [];
    final regular = ratings
        .whereType<Map>()
        .where((r) => r['ratingSystem'] == 'R')
        .firstOrNull;
    return (name: name, rating: (regular?['rating'] as num?)?.toInt());
  }
}
