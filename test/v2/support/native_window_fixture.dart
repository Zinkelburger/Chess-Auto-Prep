import 'dart:io';

import 'package:chess_auto_prep/v2/app/app_parts.dart';
import 'package:chess_auto_prep/v2/app/environment.dart';
import 'package:chess_auto_prep/v2/app/window_input.dart';
import 'package:chess_auto_prep/v2/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/v2/engines/maia/move_policy.dart';
import 'package:chess_auto_prep/v2/net/lichess_studies.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/pgn_file_store.dart';
import 'package:chess_auto_prep/v2/storage/profile_integrity.dart';
import 'package:chess_auto_prep/v2/storage/settings_store.dart';
import 'package:chess_auto_prep/v2/storage/training_store.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../storage/store_fixture.dart';
import 'my_games_fixture.dart';
import 'scripted_bughouse.dart';
import 'scripted_explorer.dart';
import 'scripted_login.dart';
import 'study_fixture.dart';
import 'viewer_fixture.dart';
import 'window_fixture.dart';

/// Production composition over disposable native repertoire, book and training
/// storage. Only unavailable outside services are scripted; no model or engine
/// process is needed to observe storage ordering and derived answers.
final class NativeWindowFixture {
  NativeWindowFixture(
    this.disk, {
    required MovePolicy policy,
    TrainingStore? progress,
  }) {
    final store = PgnFileStore(
      documents: disk.documents,
      support: disk.support,
    );
    final root = p.join(disk.documents.path, 'repertoires');
    env = AppEnvironment(
      folders: (
        repertoires: root,
        studies: p.join(disk.documents.path, 'studies'),
        collections: p.join(disk.documents.path, 'pgn_collections'),
        gamesLibrary: p.join(disk.documents.path, 'games_library'),
        tacticsSet: ChapterRef.at(
          p.join(disk.documents.path, 'tactics_sets', 'Default.pgn'),
        ),
      ),
      store: store,
      integrity: ProfileIntegrity(
        documents: disk.documents,
        support: disk.support,
      ),
      settings: SettingsStore(support: disk.support),
      chapterFiles: ChapterDirectory(Directory(root), recovery: store.recovery),
      studyFiles: ScriptedStudyFiles(),
      libraryPicker: ScriptedPicker(),
      viewerPicker: ScriptedPicker(),
      recentFiles: ScriptedRecentFiles(),
      fileImport: ScriptedImport(),
      lichessLogin: ScriptedLogin(),
      readAccount: () async => null,
      writeAccount: (_) async => true,
      lichessStudies: ScriptedLichess(
        const StudyNotFetched(StudyFetchProblem.unreachable),
      ),
      lichessExplorer: ScriptedExplorerApi(),
      masterBook: ScriptedBook(),
      gameStore: ScriptedGameStore(),
      gameSites: const [],
      accounts: MemoryAccounts(),
      books: store.books,
      progressFiles:
          progress ?? TrainingStore(disk.documents, support: disk.support),
      olderAnalyzed: () async => {},
      maia: policy,
      launchEngine: ({required cores, required memoryMb}) async =>
          const StartFailed('offline test'),
      stopEngines: () async {},
      evalCache: () => throw StateError('No engine evaluations in this test'),
      keepTree: (_, _, {required runId}) async {},
      setFullScreen: (_) async {},
      bughouse: ScriptedBughouse().outside,
      now: () => DateTime.utc(2026, 9, 25),
      saveDelay: const Duration(days: 1),
      explorerDelay: Duration.zero,
      exitWait: const Duration(milliseconds: 20),
    );
    parts = AppParts(
      env,
      question: question,
      input: DialogInput(navigator),
      copyOnLeave: (_) async => null,
    );
  }

  final StoreFixture disk;
  final navigator = GlobalKey<NavigatorState>();
  final question = ScriptedDraftQuestion();
  late final AppEnvironment env;
  late final AppParts parts;

  Future<void> ready() async {
    await parts.start();
    await parts.books.load();
    await parts.catalog.synchronize();
  }

  void dispose() => parts.dispose();
}
