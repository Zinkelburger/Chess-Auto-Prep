import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../engines/engine_supervisor.dart';
import '../features/settings/lichess_account.dart';
import '../net/lichess_login.dart';
import '../storage/chapter_files.dart';
import '../storage/pgn_file_store.dart';
import '../storage/settings_store.dart';
import '../workspace/document_saver.dart';
import '../workspace/document_session.dart';
import 'engine_launch.dart';
import 'maia_launch.dart';
import 'open_folder.dart';

/// What every part of the app is built on: the folders, the document store,
/// the settings, the one open document and its saver, the engines and the
/// network client. Built first and disposed last.
final class Basics {
  Basics({required this.documents, required this.support});

  /// The user's Documents directory; repertoires, studies and collections
  /// live under it.
  final Directory documents;

  /// The app's own folder, where the engine is installed and the settings
  /// are kept.
  final Directory support;

  late final repertoires = p.join(documents.path, 'repertoires');
  late final studies = p.join(documents.path, 'studies');
  late final collections = p.join(documents.path, 'pgn_collections');

  late final store = PgnFileStore(documents: documents, support: support);
  late final settings = SettingsStore(support: support);
  late final saver = DocumentSaver(store);
  late final session = DocumentSession(store, saver);
  late final chapterFiles = ChapterDirectory(Directory(repertoires));

  /// One HTTP client for Lichess, chess.com and the explorer.
  final client = http.Client();
  final engines = EngineSupervisor();
  final maia = MaiaLaunch();
  late final account = LichessAccountState(
    login: LichessLoginApi(client, openBrowser: openInBrowser),
  );

  /// A Stockfish with the threads and the table the settings give it now.
  Future<EngineStart> launchEngine() => launchStockfish(
    support: support,
    engines: engines,
    cores: settings.value.engineCores,
    memoryMb: settings.value.engineMemoryMb,
  );

  /// The settings are read before anything starts an engine, so its first
  /// process already has the threads and the table the user chose.
  Future<void> load() async {
    await settings.load();
    unawaited(account.load());
  }

  void dispose() {
    account.dispose();
    maia.dispose();
    settings.dispose();
    client.close();
    session.dispose();
    saver.dispose();
    unawaited(engines.dispose());
  }
}
