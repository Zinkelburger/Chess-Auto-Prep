import 'package:http/http.dart' as http;
import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart';

class ImportedGamesService {
  static const String _lichessBase = 'https://lichess.org';
  static const String _apiBase = 'https://lichess.org/api/games/export/_ids';
  static const int _batchSize = 300;

  /// Scrape game IDs from the Lichess imported games web page
  Future<List<String>> scrapeImportedGameIds(String username, {int? maxGames}) async {
    print('Scraping imported game IDs for user: $username...');

    final List<String> gameIds = [];
    int page = 1;

    while (gameIds.length < (maxGames ?? double.infinity)) {
      final String url = page == 1
          ? '$_lichessBase/@/$username/imported'
          : '$_lichessBase/@/$username/imported?page=$page';

      print('Scraping page $page...');

      try {
        final response = await http.get(Uri.parse(url));
        response.body; // Force evaluation

        if (response.statusCode != 200) {
          throw Exception('HTTP ${response.statusCode}: ${response.reasonPhrase}');
        }

        final Document document = html_parser.parse(response.body);

        // Find all game row overlay links (same CSS selector as Python version)
        final List<Element> gameLinks = document.querySelectorAll('a.game-row__overlay');

        if (gameLinks.isEmpty) {
          print('No more games found on page $page');
          break;
        }

        final List<String> pageGameIds = [];
        for (final link in gameLinks) {
          final String? href = link.attributes['href'];
          if (href != null) {
            // Extract game ID from href like "/Aq9fm8DR" or "/H9rG4JaC/black"
            final List<String> parts = href.split('/');
            if (parts.length > 1) {
              final String gameId = parts[1].split('/')[0]; // Get first part after /
              gameIds.add(gameId);
              pageGameIds.add(gameId);

              if (maxGames != null && gameIds.length >= maxGames) {
                break;
              }
            }
          }
        }

        print('Found ${gameLinks.length} games on page $page, total: ${gameIds.length}');
        print('Game IDs from page $page: $pageGameIds');
        page++;

        // Be polite to the server
        await Future.delayed(const Duration(seconds: 1));

      } catch (e) {
        print('Error scraping page $page: $e');
        break;
      }
    }

    print('Total game IDs scraped: ${gameIds.length}');
    return maxGames != null ? gameIds.take(maxGames).toList() : gameIds;
  }

  /// Download games by their IDs in batches with evaluations
  Future<String> downloadGamesWithEvals(
    List<String> gameIds,
    String? token, {
    Function(String)? progressCallback,
  }) async {
    if (gameIds.isEmpty) {
      progressCallback?.call('No game IDs to download.');
      return '';
    }

    progressCallback?.call('Preparing to download ${gameIds.length} games with evaluations...');

    final Map<String, String> headers = {
      'Content-Type': 'text/plain',
      'Accept': 'application/x-chess-pgn',
    };

    final StringBuffer allPgns = StringBuffer();

    // Process games in batches
    final int totalBatches = (gameIds.length / _batchSize).ceil();

    for (int i = 0; i < gameIds.length; i += _batchSize) {
      final List<String> batchIds = gameIds.skip(i).take(_batchSize).toList();
      final int batchNum = (i / _batchSize).floor() + 1;

      progressCallback?.call('Downloading batch $batchNum/$totalBatches (${batchIds.length} games)...');

      // API expects comma-separated string of IDs
      final String postData = batchIds.join(',');

      print('\nDEBUG - Batch $batchNum:');
      print('  Game IDs in batch: $batchIds');
      print('  POST data: ${postData.length > 200 ? '${postData.substring(0, 200)}...' : postData}');
      print('  API URL: $_apiBase');
      print('  Headers: $headers');

      final Map<String, String> params = {
        'evals': 'true',
        'clocks': 'true',
        'literate': 'true',
      };

      try {
        final Uri uri = Uri.parse(_apiBase).replace(queryParameters: params);
        final response = await http.post(
          uri,
          headers: headers,
          body: postData,
        );

        print('  Response status: ${response.statusCode}');
        print('  Response headers: ${response.headers}');

        if (response.statusCode != 200) {
          throw Exception('HTTP ${response.statusCode}: ${response.reasonPhrase}');
        }

        allPgns.write(response.body);
        allPgns.write('\n\n');

        progressCallback?.call('Batch $batchNum/$totalBatches downloaded successfully');

        // Be polite to the API
        if (gameIds.length > _batchSize) {
          await Future.delayed(const Duration(seconds: 2));
        }

      } catch (e) {
        final String errorMsg = 'Error downloading batch $batchNum: $e';
        progressCallback?.call(errorMsg);
        throw Exception(errorMsg);
      }
    }

    progressCallback?.call('Download complete! ${gameIds.length} games downloaded.');
    return allPgns.toString();
  }

  /// Main function to import Lichess games with evaluations
  Future<String> importLichessGamesWithEvals(
    String username,
    String? token, {
    int maxGames = 100,
    Function(String)? progressCallback,
  }) async {
    try {
      // Scrape game IDs from web page
      progressCallback?.call('Scraping game IDs for user: $username');

      final List<String> gameIds = await scrapeImportedGameIds(username, maxGames: maxGames);

      if (gameIds.isEmpty) {
        throw Exception('No imported game IDs found to download');
      }

      progressCallback?.call('Found ${gameIds.length} games to download');

      // Download with evaluations
      final String pgns = await downloadGamesWithEvals(
        gameIds,
        token,
        progressCallback: progressCallback,
      );

      return pgns;

    } catch (e) {
      progressCallback?.call('Error: ${e.toString()}');
      rethrow;
    }
  }
}