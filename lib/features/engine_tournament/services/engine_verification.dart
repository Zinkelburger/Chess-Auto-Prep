/// Prove a binary is actually a UCI chess engine before letting it compete.
///
/// The user can point this feature at any file on disk. A wrong pick is the
/// normal case, not the exceptional one — a wrapper script, a GUI, an
/// XBoard-only engine, a Windows `.exe` on Linux — and every one of those
/// fails in a different, unhelpful way if it is only discovered mid-game. So
/// a candidate has to walk the whole path first: start, speak UCI, answer
/// `isready`, and produce a **legal** move from the standard position.
library;

import 'dart:io';

// dartchess exports its own `File` (a board file, a-h); `dart:io`'s is the
// one this module means.
import 'package:dartchess/dartchess.dart' hide File;

import '../../../constants/chess_constants.dart';
import 'uci_engine.dart';

class EngineVerification {
  const EngineVerification({
    required this.ok,
    required this.message,
    this.name = '',
    this.author = '',
    this.options = const [],
    this.sampleMove = '',
    this.transcript = const [],
  });

  final bool ok;

  /// Why it failed, or a one-line summary of what answered.
  final String message;

  final String name;
  final String author;
  final List<UciOptionInfo> options;

  /// The move it produced from the starting position, in SAN.
  final String sampleMove;

  /// First lines the engine printed — shown when it fails, because the
  /// giveaway ("This is an XBoard engine") is usually right there.
  final List<String> transcript;

  bool get supportsHash => _has('Hash');
  bool get supportsThreads => _has('Threads');
  bool get supportsMultiPv => _has('MultiPV');
  bool get supportsPonder => _has('Ponder');

  bool _has(String option) =>
      options.any((o) => o.name.toLowerCase() == option.toLowerCase());
}

/// Run the full check against [executablePath].
///
/// Never throws: a failure is a result, since the whole point is to report
/// it back to the person who picked the file.
Future<EngineVerification> verifyUciEngine(
  String executablePath, {
  List<String> arguments = const [],
  Duration handshakeTimeout = const Duration(seconds: 15),
  Duration moveTimeout = const Duration(seconds: 20),
}) async {
  final file = File(executablePath);
  if (!file.existsSync()) {
    if (Directory(executablePath).existsSync()) {
      return const EngineVerification(
        ok: false,
        message: 'That is a folder, not an engine binary.',
      );
    }
    return const EngineVerification(ok: false, message: 'No such file.');
  }
  if (!Platform.isWindows && !_isExecutable(file)) {
    return const EngineVerification(
      ok: false,
      message:
          'The file is not executable. Run `chmod +x` on it and try again.',
    );
  }

  UciEngine? engine;
  final transcript = <String>[];
  try {
    engine = await UciEngine.launch(
      executablePath: executablePath,
      arguments: arguments,
    );
    final sub = engine.traffic.listen((line) {
      if (transcript.length < 40) transcript.add(line);
    });

    final UciIdentity identity;
    try {
      identity = await engine.initialize(timeout: handshakeTimeout);
    } on UciFailure catch (e) {
      await sub.cancel();
      return EngineVerification(
        ok: false,
        message:
            'It started, but never answered "uci" with "uciok" — so it is '
            'not a UCI engine.\n${e.message}',
        transcript: List.of(transcript),
      );
    }

    try {
      await engine.isReady(timeout: handshakeTimeout);
    } on UciFailure catch (e) {
      await sub.cancel();
      return EngineVerification(
        ok: false,
        message: '"${identity.name}" did not answer "isready".\n${e.message}',
        name: identity.name,
        author: identity.author,
        options: identity.options,
        transcript: List.of(transcript),
      );
    }

    // The handshake is cheap to fake; playing a legal move is not.
    final EngineSearch search;
    try {
      await engine.newGame();
      search = await engine.search(
        startFen: kStandardStartFen,
        movesUci: const [],
        limits: const GoLimits(movetimeMs: 300),
        hardLimit: moveTimeout,
      );
    } on UciFailure catch (e) {
      await sub.cancel();
      return EngineVerification(
        ok: false,
        message:
            '"${identity.name}" never produced a move from the starting '
            'position.\n${e.message}',
        name: identity.name,
        author: identity.author,
        options: identity.options,
        transcript: List.of(transcript),
      );
    }

    await sub.cancel();

    if (!search.hasMove) {
      return EngineVerification(
        ok: false,
        message:
            '"${identity.name}" answered "bestmove ${search.bestMoveUci}" '
            'from the starting position, which is not a move.',
        name: identity.name,
        author: identity.author,
        options: identity.options,
        transcript: List.of(transcript),
      );
    }

    final start = Chess.fromSetup(Setup.parseFen(kStandardStartFen));
    final move = Move.parse(search.bestMoveUci);
    if (move == null || !start.isLegal(move)) {
      return EngineVerification(
        ok: false,
        message:
            '"${identity.name}" answered "${search.bestMoveUci}" from the '
            'starting position, which is not a legal move. It speaks UCI but '
            'is not playing chess.',
        name: identity.name,
        author: identity.author,
        options: identity.options,
        transcript: List.of(transcript),
      );
    }

    return EngineVerification(
      ok: true,
      message: 'Verified — answered "uci", "isready", and played a legal move.',
      name: identity.name,
      author: identity.author,
      options: identity.options,
      sampleMove: start.makeSan(move).$2,
      transcript: List.of(transcript),
    );
  } on UciFailure catch (e) {
    return EngineVerification(
      ok: false,
      message: e.message,
      transcript: List.of(transcript),
    );
  } catch (e) {
    return EngineVerification(
      ok: false,
      message: '$e',
      transcript: List.of(transcript),
    );
  } finally {
    await engine?.quit();
  }
}

bool _isExecutable(File file) {
  try {
    final mode = file.statSync().mode;
    return mode & 0x49 != 0; // any of owner/group/other execute bits
  } catch (_) {
    return true;
  }
}
