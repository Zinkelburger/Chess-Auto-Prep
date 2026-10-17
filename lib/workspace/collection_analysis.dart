import 'dart:async';

import 'package:flutter/foundation.dart';

import '../chess/pgn/analysis_board.dart';
import '../chess/pgn/chapter.dart';
import '../engines/engine_supervisor.dart';
import '../storage/pgn_document_store.dart';
import 'document_actions.dart';
import 'document_history.dart';
import 'document_saver.dart';
import 'document_session.dart';
import 'engine_analysis.dart';

/// A scratch game inside its source collection. The source session never
/// changes, so its game list, filters, draft and file tab remain in place.
/// Each source game keeps its own analysis and undo history for this window.
final class CollectionAnalysis extends ChangeNotifier {
  CollectionAnalysis({
    required this.source,
    required PgnDocumentStore store,
    required Future<EngineStart> Function() launch,
    required this.sourceEngine,
    required int multiPv,
  }) {
    saver = DocumentSaver(store);
    session = DocumentSession(store, saver);
    engine = EngineAnalysis(session, launch, multiPv: multiPv);
    engine.pause(this, 'Analysis tab is hidden');
    source.anyChange.addListener(_followSource);
  }

  final DocumentSession source;
  final EngineAnalysis sourceEngine;
  late final DocumentSaver saver;
  late final DocumentSession session;
  late final EngineAnalysis engine;
  final _pages = <Object, KeptBoard>{};
  Object? _key;
  int _generation = 0;
  bool _disposed = false;
  bool active = false;

  Object get _sourceKey => (source.source ?? source.analysisPage, source.game);

  void _followSource() {
    if (_key != _sourceKey) hide();
  }

  /// Reopen this game's scratch work, or copy its complete game at the
  /// current cursor, including variations, annotations and a comment preview.
  Future<bool> show() async {
    if (_disposed || source.shownTo != null) return false;
    source.snapshot();
    final key = _sourceKey;
    final ticket = ++_generation;
    final cursor = source.cursor.value;
    final side = source.orientation;
    final preview = source.cursor.commentLine.value;
    var page = _pages[key];
    final created = page == null;
    if (page == null) {
      final chapter = withSide(
        await readChapter(name: analysisBoardName, text: gameText(source)),
        side,
      );
      if (_disposed || ticket != _generation || key != _sourceKey) return false;
      page = KeptBoard(chapter)..cursor = cursor;
      _pages[key] = page;
    }
    if (!await session.restoreAnalysisPage(page) ||
        _disposed ||
        ticket != _generation ||
        key != _sourceKey)
      return false;
    if (preview != null && created) {
      for (final move in preview.moves.take(preview.at + 1)) {
        session.playMove(move.uci);
      }
    }
    _key = key;
    active = true;
    sourceEngine.pause(this, 'Analysis tab is on the board');
    engine.resume(this);
    notifyListeners();
    unawaited(engine.enable());
    return true;
  }

  /// Paste stays in this scratch game and cannot replace the source file.
  /// Answers why nothing was pasted, or null.
  Future<String?> paste(String text, {bool positionOnly = false}) async {
    switch (positionOnly
        ? pastedPosition(text)
        : pastedBoard(text, side: session.orientation)) {
      case PasteRefused(:final reason):
        return reason;
      case PastedBoard(:final chapter):
        await put(chapter);
        return null;
    }
  }

  /// [board] as this game's scratch work, in place of what it was.
  Future<void> put(Chapter board) async {
    final key = _sourceKey;
    final ticket = ++_generation;
    if (!await session.showAnalysisBoard(board) ||
        _disposed ||
        ticket != _generation ||
        key != _sourceKey)
      return;
    _pages[key] = session.analysisPage;
  }

  void hide() {
    _generation++;
    if (!active) return;
    // The same page is reused on return; capture even if no other page is shown.
    session.snapshot();
    session.analysisPage
      ..chapter = session.chapter!
      ..cursor = session.cursor.value;
    active = false;
    engine.pause(this, 'Analysis tab is hidden');
    sourceEngine.resume(this);
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    hide();
    source.anyChange.removeListener(_followSource);
    engine.dispose();
    session.dispose();
    saver.dispose();
    super.dispose();
  }
}
