import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartchess/dartchess.dart' hide File;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../../app_version.dart';
import '../../../utils/log.dart';
import '../models/bughouse_engine_settings.dart';
import '../models/bughouse_state.dart';
import 'bughouse_bundle.dart';
import 'windows_loader_check.dart';

/// Thrown when the engine cannot be started or does not answer in time.
class BughouseEngineFailure implements Exception {
  BughouseEngineFailure(this.message, {this.report});

  /// One line, for the banner.
  final String message;

  /// Everything a bug report needs, or null when there was nothing to gather.
  ///
  /// Separate from [message] because they have different readers: the banner
  /// wants a sentence, and whoever has to fix it wants the file sizes, the
  /// command line, the library resolution table and the engine's own stderr.
  /// Putting both in one string meant the panel either showed a wall of text
  /// or threw the useful half away.
  final String? report;

  @override
  String toString() => 'BughouseEngineFailure: $message';
}

/// What a caller needs from a bughouse engine, without a process behind it.
///
/// [BughouseEngine] is the real implementation and starts Hivemind; this
/// interface exists so the controller's analysis loop — which is where all the
/// hard parts live (a pump that alternates teams, generation invalidation,
/// scenario comparison) — can be driven by a scripted fake in tests. Without
/// it the only injectable engine was a real 54 MB process, which is why none
/// of that code had any coverage.
abstract class BughouseAnalysisEngine {
  /// Which inference backend the engine reported at load.
  String get backend;

  /// How that backend is running: workers, intra-op threads and the inference
  /// batch, as the engine itself reported them.
  ///
  /// This is the answer to "how many cores does it use", and it is a readout
  /// rather than a control because Hivemind does not advertise a `Threads`
  /// option — see [BughouseEngineSettings]. It is re-reported whenever
  /// `BatchSize` changes, so it stays true after a settings change.
  String get backendDetail;

  /// Sets one UCI option and waits for the engine to acknowledge it.
  Future<void> setOption(String name, Object value);

  /// False once the process has exited, however it exited.
  bool get isAlive;

  /// Live `info` lines for the search in progress.
  Stream<BughouseInfo> get infoStream;

  Future<void> configure({
    required Side team,
    required bool hasTimeAdvantage,
    RequireMoveOn requireMoveOn,
    int multiPv,
  });

  Future<void> setPosition(BughouseState state, {List<String> moves});

  /// Runs one search.
  ///
  /// Implementations must cross a real event-loop turn — process I/O, or a
  /// timer in a fake. The analysis pump calls this in a loop, so an
  /// implementation that answered purely from microtasks would keep the
  /// microtask queue non-empty forever and starve every timer in the isolate,
  /// including the ones that would have stopped it.
  Future<BughouseSearchResult> search({
    Duration? movetime,
    int? nodes,
    Duration timeout,
  });

  /// Interrupts a running search; `bestmove` still follows.
  void stop();

  Future<void> dispose();
}

/// A client for Hivemind, the neural-network bughouse engine.
///
/// It speaks UCI, but not the UCI a chess GUI expects: bughouse needs two
/// boards, so the dialect differs in three ways that this class hides.
///
///   * `position fen <boardA>|<boardB>` — two crazyhouse FENs, pipe-separated.
///   * Moves carry a board digit: `1e2e4` is e2e4 on board A, `2d7d5` on B.
///   * `bestmove (d2d4,pass)` — a *joint* action, one half per board, where
///     `pass` (deliberately not moving) is a legal and often correct choice.
///
/// `go` is asynchronous and the engine keeps thinking in a permanent-brain
/// loop afterwards, so callers must wait for `bestmove` rather than firing
/// commands back to back — sending `quit` straight after `go` aborts the
/// search before a single node is expanded.
///
/// One process answers one question at a time, and this class is what enforces
/// that: every public method queues on [_serialise]. The completers below hold
/// a single waiter each, so two callers overlapping would hand one of them the
/// other's `readyok` or `bestmove` — and there are three callers (the analysis
/// pump, the scenario comparison, and the pause button), which is too many to
/// keep in step by convention.
class BughouseEngine implements BughouseAnalysisEngine {
  BughouseEngine._(this._process, this.executablePath, this.modelPath) {
    _stdoutSub = _process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          _spoke = true;
          // The first handful only, and only for a failure report: the banner
          // and the backend line say what the engine thought it was doing, and
          // after that it is search output nobody wants pasted into an issue.
          if (_stdoutLines.length < 24) _stdoutLines.add(line.trimRight());
          _onLine(line);
        });
    _stderrSub = _process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_stderrLines.add);
    // A crashed engine used to be invisible: nothing failed the pending
    // completer, so the next search waited out its full ten-minute timeout and
    // `_engine` kept handing back the corpse.
    unawaited(
      _process.exitCode.then((code) {
        _exited = true;
        _exitStatus = code;
        if (!_disposed) _failPending(describeExit(code));
      }),
    );
  }

  final Process _process;
  final String executablePath;
  final String modelPath;

  late final StreamSubscription<String> _stdoutSub;
  late final StreamSubscription<String> _stderrSub;

  final List<String> _stderrLines = [];
  final List<String> _stdoutLines = [];

  /// How the process was started, kept for the failure report. A user who has
  /// to reproduce the launch by hand needs the exact command line, and the
  /// working directory is load-bearing on Windows.
  late final List<String> _argv;
  late final String _workingDirectory;
  late final Map<String, String> _childEnvironment;

  /// The exit code, once there is one.
  int? _exitStatus;

  /// Whether the process has ever written a line to stdout.
  ///
  /// The difference between "the engine is loading a 54 MB network slowly" and
  /// "the engine never ran at all" — Hivemind prints its banner before it
  /// touches the network, so an engine that has said nothing has not reached
  /// `main`. On Windows that is what a missing DLL looks like from here: the
  /// loader stops the process with a modal error, so it neither speaks nor
  /// exits, and a bare timeout is the least informative thing to report.
  bool _spoke = false;
  final _infoController = StreamController<BughouseInfo>.broadcast();

  Completer<void>? _readyCompleter;
  Completer<void>? _uciOkCompleter;
  Completer<_SearchResult>? _searchCompleter;

  /// Where `info` lines land while a search is running. Null between searches.
  List<BughouseInfo>? _searchInfos;

  /// How many `info` lines one search keeps. Generous — a 30-second pass emits
  /// a couple of dozen — but bounded, because nothing else bounds it.
  static const int _maxInfos = 512;

  bool _disposed = false;
  bool _exited = false;
  String _name = 'hivemind';
  String _backend = '';
  String _backendDetail = '';

  /// The `TimeAdvantage` the current search was configured with. Stamped onto
  /// every parsed line, because it is most of what that line's raw score is
  /// made of — the network reads the bit as about ±0.58 of Q — and so decides
  /// which searches may be read against each other at all.
  bool _timeAdvantage = false;

  /// Serialises every command: one process answers one question at a time.
  Future<void> _queue = Future<void>.value();

  /// Engine name from `id name`.
  String get name => _name;

  /// Which inference backend the engine reported at load — "ONNX Runtime
  /// (CPU)" for the portable build, "TensorRT" when it found a GPU.
  @override
  String get backend => _backend;

  @override
  String get backendDetail => _backendDetail;

  @override
  bool get isAlive => !_exited && !_disposed;

  /// Live `info` lines for the search in progress.
  @override
  Stream<BughouseInfo> get infoStream => _infoController.stream;

  /// Runs [body] after every command already queued, so two callers cannot
  /// interleave `setoption`/`position`/`go` on one stdin or race for the
  /// single-slot completers. A failure does not poison the queue.
  ///
  /// Also the one place every command failure passes through, so it is where a
  /// diagnostic gets attached. A launch that never answered was already
  /// reported in full; an engine that died *during* a session was not, and
  /// reached the user as "Engine exited (139)" with nothing behind it — the
  /// same unreadable failure in a different place.
  Future<T> _serialise<T>(Future<T> Function() body) {
    final result = _queue.then((_) => body()).onError<BughouseEngineFailure>((
      e,
      stack,
    ) async {
      if (e.report != null) throw e;
      throw BughouseEngineFailure(
        e.message,
        report: await buildReport(headline: e.message),
      );
    });
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// Everything the engine wrote to stderr, for surfacing load failures
  /// (a missing model, an FP16 network) instead of a bare timeout.
  List<String> get diagnostics => List.unmodifiable(_stderrLines);

  static Future<BughouseEngine> launch({
    required String executablePath,
    required String modelPath,

    /// Directory holding libonnxruntime. The bundled binary is built with an
    /// RPATH from the build machine, so the runtime has to be found by
    /// environment instead of by embedded path.
    String? libraryPath,
    Duration timeout = const Duration(seconds: 90),
  }) async {
    if (!await File(executablePath).exists()) {
      throw BughouseEngineFailure('Engine binary not found: $executablePath');
    }
    if (!await File(modelPath).exists()) {
      throw BughouseEngineFailure('Network not found: $modelPath');
    }

    final engineDir = File(executablePath).parent.path;
    final environment = <String, String>{};
    if (Platform.isWindows) {
      // Windows has no loader-path variable to set: it resolves a process's
      // imports against the directory of the process's own image first, which
      // is where BughouseBundle puts every library the engine needs. The rest
      // of the search order — the working directory, then everything on PATH —
      // is the user's machine, and it is pure risk: a 32-bit MSVCP140.dll left
      // on PATH by some unrelated toolchain is loaded ahead of the system one
      // and stops the engine before `main` with STATUS_INVALID_IMAGE_FORMAT,
      // which the app can only see as a process that started, said nothing and
      // exited. Nothing the engine imports lives outside its own directory or
      // System32, so cutting PATH down to those takes that entire class of
      // machine-specific failure away.
      //
      // The variable keeps whatever spelling the parent used: Windows
      // environment names are case-insensitive, but the block handed to
      // CreateProcess is an ordered list, so adding a second "PATH" beside an
      // inherited "Path" would leave which of them wins to chance.
      final root = Platform.environment['SystemRoot'] ?? r'C:\Windows';
      final key = Platform.environment.keys.firstWhere(
        (k) => k.toLowerCase() == 'path',
        orElse: () => 'PATH',
      );
      environment[key] = [
        engineDir,
        p.join(root, 'System32'),
        root,
        p.join(root, 'System32', 'Wbem'),
      ].join(';');
    } else if (libraryPath != null) {
      final key = Platform.isMacOS ? 'DYLD_LIBRARY_PATH' : 'LD_LIBRARY_PATH';
      final existing = Platform.environment[key];
      environment[key] = existing == null || existing.isEmpty
          ? libraryPath
          : '$libraryPath:$existing';
    }

    // The model is named relative to the working directory whenever it sits
    // beside the engine, which is every shipped install.
    //
    // Not a micro-optimisation: the support directory is
    // `…\com.example\Chess Auto Prep\bughouse` on Windows, so the absolute
    // path contains spaces, and every path this feature was ever tested
    // against — this repo, both CI runners, both temp directories — does not.
    // Whether an argument survives the round trip through a Windows command
    // line is then a question the tests cannot ask. A bare filename cannot be
    // split by any quoting rule, so the question stops being one.
    final argv = <String>['--model', modelArgument(modelPath, engineDir)];

    final Process process;
    try {
      process = await Process.start(
        executablePath,
        argv,
        // The engine's own directory, so the last unpinned entry in the
        // loader's search order is one we control too. It is also simply the
        // right answer: every file the engine touches lives there.
        workingDirectory: engineDir,
        environment: environment.isEmpty ? null : environment,
        includeParentEnvironment: true,
      );
    } on ProcessException catch (e) {
      throw BughouseEngineFailure('Could not start the engine: ${e.message}');
    }

    final engine = BughouseEngine._(process, executablePath, modelPath)
      .._argv = argv
      .._workingDirectory = engineDir
      .._childEnvironment = {...Platform.environment, ...environment};
    try {
      await engine._handshake(timeout);
    } catch (e) {
      // The one moment worth spending real time on diagnosis: a first launch
      // that never answered is the failure users actually hit, and "did not
      // answer" on its own tells them nothing they can act on.
      final report = await engine.buildReport(
        headline: e is BughouseEngineFailure ? e.message : '$e',
      );
      await engine.dispose();
      final message = e is BughouseEngineFailure ? e.message : '$e';
      log.e('Bughouse engine failed to start\n$report');
      throw BughouseEngineFailure(message, report: report);
    }
    return engine;
  }

  /// How the network is named on the command line, given that the process is
  /// started with [engineDir] as its working directory.
  ///
  /// The bare filename whenever the network sits beside the engine, which is
  /// every shipped install. See the comment at the call site: the support
  /// directory contains a space on Windows and no path this feature has ever
  /// been tested against does, so an absolute path here is the one argument
  /// whose survival through a command line nothing has checked.
  @visibleForTesting
  static String modelArgument(String modelPath, String engineDir) =>
      p.equals(p.dirname(modelPath), engineDir)
      ? p.basename(modelPath)
      : modelPath;

  Future<void> _handshake(Duration timeout) async {
    _uciOkCompleter = Completer<void>();
    _send('uci');
    await _await(_uciOkCompleter!, timeout, 'uci');
    await _isReady(timeout: timeout);
  }

  /// Which side the engine plays on board A, whether it is up on the diagonal
  /// clock, and whether it is forced to move on one board.
  ///
  /// Time advantage is not cosmetic: it decides whether sitting on both boards
  /// is legal at all. [requireMoveOn] goes further and forbids passing on the
  /// named board, which is the only way to ask "what if I simply have to move
  /// here" — the engine's clock model is otherwise a single bit, so "level"
  /// and "behind" are the same search to it.
  @override
  Future<void> configure({
    required Side team,
    required bool hasTimeAdvantage,
    RequireMoveOn requireMoveOn = RequireMoveOn.none,
    int multiPv = 1,
  }) => _serialise(() async {
    _send(
      'setoption name Team value ${team == Side.white ? 'white' : 'black'}',
    );
    _timeAdvantage = hasTimeAdvantage;
    _send('setoption name TimeAdvantage value $hasTimeAdvantage');
    _send('setoption name RequireMoveOn value ${requireMoveOn.uciValue}');
    _send('setoption name MultiPV value ${multiPv < 1 ? 1 : multiPv}');
    await _isReady();
  });

  @override
  Future<void> setOption(String name, Object value) => _serialise(() async {
    _send('setoption name $name value $value');
    await _isReady();
  });

  Future<void> newGame() => _serialise(() async {
    _send('ucinewgame');
    await _isReady();
  });

  Future<void> isReady({Duration timeout = const Duration(seconds: 60)}) =>
      _serialise(() => _isReady(timeout: timeout));

  /// The round-trip itself, already inside the queue.
  Future<void> _isReady({
    Duration timeout = const Duration(seconds: 60),
  }) async {
    _readyCompleter = Completer<void>();
    _send('isready');
    await _await(_readyCompleter!, timeout, 'isready');
  }

  /// Sets the two-board position. [moves] are joint half-moves already
  /// carrying their board prefix.
  @override
  Future<void> setPosition(
    BughouseState state, {
    List<String> moves = const [],
  }) => _serialise(() async {
    final suffix = moves.isEmpty ? '' : ' moves ${moves.join(' ')}';
    _send('position fen ${state.dualFen}$suffix');
    await _isReady();
  });

  /// Searches the current position and resolves when `bestmove` arrives.
  ///
  /// Exactly one of [movetime] / [nodes] should be given; with neither the
  /// engine defaults to one second.
  @override
  Future<BughouseSearchResult> search({
    Duration? movetime,
    int? nodes,
    Duration timeout = const Duration(minutes: 10),
  }) => _serialise(() => _search(movetime, nodes, timeout));

  Future<BughouseSearchResult> _search(
    Duration? movetime,
    int? nodes,
    Duration timeout,
  ) async {
    if (_disposed) throw BughouseEngineFailure('Engine has been disposed');
    if (_exited) {
      throw BughouseEngineFailure(
        'Engine is not running.${_stderrLines.isEmpty ? '' : '\n${_stderrLines.take(8).join('\n')}'}',
      );
    }
    _searchCompleter = Completer<_SearchResult>();
    // Collected as the lines are read, not through [infoStream]: a broadcast
    // stream delivers asynchronously, so the engine's final MultiPV block —
    // printed immediately before `bestmove` — loses the race with the
    // completer and the shortlist arrives empty.
    final infos = _searchInfos = <BughouseInfo>[];

    if (nodes != null) {
      _send('go nodes $nodes');
    } else if (movetime != null) {
      _send('go movetime ${movetime.inMilliseconds}');
    } else {
      _send('go');
    }

    try {
      final result = await _await(_searchCompleter!, timeout, 'go');
      return BughouseSearchResult(
        best: result.best,
        ponder: result.ponder,
        infos: List.unmodifiable(infos),
      );
    } finally {
      _searchInfos = null;
      // Left alone the engine keeps a permanent-brain search on every core
      // between calls, starving the next one.
      _send('stop');
    }
  }

  /// Interrupts a running search; `bestmove` still follows.
  ///
  /// Deliberately *not* serialised: its whole job is to cut short a command
  /// that is already at the head of the queue.
  @override
  void stop() => _send('stop');

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      _send('stop');
      _send('quit');
      await _process.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          _process.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
    } catch (_) {
      _process.kill(ProcessSignal.sigkill);
    }
    await _stdoutSub.cancel();
    await _stderrSub.cancel();
    await _infoController.close();
    _failPending('Engine stopped');
  }

  // ---------------------------------------------------------------- internals

  void _send(String command) {
    try {
      _process.stdin.writeln(command);
    } catch (_) {
      // The process died; pending waiters time out or fail below.
    }
  }

  Future<T> _await<T>(Completer<T> completer, Duration timeout, String what) {
    return completer.future.timeout(
      timeout,
      onTimeout: () => throw BughouseEngineFailure(
        stalledMessage(
          what: what,
          timeout: timeout,
          spoke: _spoke,
          stderr: _stderrLines,
          isWindows: Platform.isWindows,
        ),
      ),
    );
  }

  /// What to say when the engine is still running but has stopped answering.
  ///
  /// Split out and pure because the interesting case is the one that is
  /// hardest to reproduce: a Windows machine where the process exists, has
  /// printed nothing, and never will. Hivemind's banner goes out before it
  /// opens the network, so silence is not slowness — it is a process the
  /// loader stopped before `main`, which on Windows means a missing DLL and
  /// usually a modal error box behind the app window.
  @visibleForTesting
  static String stalledMessage({
    required String what,
    required Duration timeout,
    required bool spoke,
    required List<String> stderr,
    required bool isWindows,
  }) {
    final buffer = StringBuffer(
      'Engine did not answer "$what" within ${timeout.inSeconds}s',
    );
    if (stderr.isNotEmpty) {
      buffer.write('\n${stderr.take(8).join('\n')}');
    } else if (!spoke) {
      buffer.write(
        '\nThe engine started but printed nothing at all, so it never got as '
        'far as loading the network.',
      );
      if (isWindows) {
        buffer.write(
          ' On Windows that is what a missing system library looks like — '
          'check for an error box behind the app window, and install the '
          'Microsoft Visual C++ Redistributable (x64) if one names a DLL.',
        );
      }
    }
    return buffer.toString();
  }

  /// A process exit turned into something worth showing a user.
  ///
  /// Windows reports a loader failure as an NTSTATUS in the exit code, which
  /// reaches Dart as either the unsigned DWORD or its signed reading depending
  /// on the path it took — both spellings are matched here. A bare
  /// "Engine exited (-1073741515)" is the single least actionable thing this
  /// class can say, and it is also the most likely thing it will ever say on a
  /// machine that has never installed the Visual C++ redistributable.
  ///
  /// Unix has the same problem in a different alphabet: a process killed by a
  /// signal reaches Dart as the negated signal number, so "Engine exited (-4)"
  /// is how "this CPU does not have AVX" and "the OOM killer took it" both
  /// look. [isWindows] chooses the alphabet rather than reading [Platform] so
  /// both readings stay testable on one machine.
  @visibleForTesting
  static String describeExit(int code, {bool? isWindows}) {
    final windows = isWindows ?? Platform.isWindows;
    // A process killed by a signal reaches Dart as the negated signal number,
    // and signals stop at 64; anything more negative is a Windows NTSTATUS
    // that arrived through a signed path, which is why the two readings can
    // share one function without a platform flag at every call site.
    if (!windows && (code == 126 || code == 127)) {
      // What the dynamic loader exits with when it cannot start the program at
      // all. 127 in particular is what a missing or unreadable
      // libonnxruntime.so.1 looks like, and the loader has already written the
      // name of the library it could not open to stderr — which the report
      // below quotes, so this only has to point at it.
      return 'The bughouse engine could not start: the system could not load '
          'one of its shared libraries (exit $code). The engine\'s own error '
          'below names which one.';
    }
    if (!windows && code < 0 && -code <= 64) {
      final hint = switch (-code) {
        4 =>
          'this CPU does not support an instruction the engine was built with '
              '(SIGILL).',
        6 =>
          'it aborted (SIGABRT) — the stderr above says why, if anything does.',
        7 || 10 =>
          'it died on a bus error (SIGBUS), usually a truncated or '
              'corrupted network file.',
        9 =>
          'the system killed it outright (SIGKILL), which on a desktop is '
              'almost always the out-of-memory killer. The network needs about '
              '1 GB of RAM to load.',
        11 => 'it crashed (SIGSEGV).',
        _ => null,
      };
      return hint == null
          ? 'Engine exited on signal ${-code}'
          : 'The bughouse engine could not start: $hint';
    }
    final status = code < 0 ? code + 0x100000000 : code;
    final hint = switch (status) {
      0xC0000135 =>
        'a library it needs is missing. Install the Microsoft Visual C++ '
            'Redistributable (x64) and try again.',
      0xC0000139 =>
        'one of its libraries is the wrong version — it loaded, but does not '
            'have a function the engine needs.',
      0xC0000142 => 'one of its libraries failed to initialise.',
      0xC000007B =>
        'Windows refused one of its libraries as an invalid 64-bit image. '
            'That is either a 32-bit copy of it found ahead of the right one, '
            'or a file that did not finish being written.',
      0xC000001D =>
        'this CPU does not support an instruction the engine was built with.',
      0xC0000005 => 'it crashed (access violation).',
      0xC0000409 => 'it was stopped by a stack buffer overrun check.',
      _ => null,
    };
    return hint == null
        ? 'Engine exited ($code)'
        : 'The bughouse engine could not start: $hint';
  }

  /// Everything a bug report about a failed launch needs, as one block of
  /// text the user can copy in a single click.
  ///
  /// Assembled rather than logged piecemeal because the reader is usually not
  /// the person who can read a log: the whole point is that someone can send
  /// this back without knowing what any of it means. Best effort by
  /// construction — it only ever runs on a path that has already failed, so
  /// anything it threw would replace a real diagnosis with a worse one.
  Future<String> buildReport({required String headline}) async {
    try {
      final directory = await describeDirectory(
        _workingDirectory,
        BughouseBundle.expectedSizes,
      );
      List<DllResolution>? libraries;
      if (Platform.isWindows) {
        libraries = await WindowsLoaderCheck.resolveAll(
          engineDir: _workingDirectory,
          environment: _childEnvironment,
        );
      }
      final loaderVariable = Platform.isMacOS
          ? 'DYLD_LIBRARY_PATH'
          : 'LD_LIBRARY_PATH';
      return formatReport(
        headline: headline,
        executablePath: executablePath,
        argv: _argv,
        workingDirectory: _workingDirectory,
        exitCode: _exitStatus,
        spoke: _spoke,
        directory: directory,
        libraries: libraries,
        stdout: _stdoutLines,
        stderr: _stderrLines,
        loaderPath: Platform.isWindows
            ? null
            : '$loaderVariable=${_childEnvironment[loaderVariable] ?? '(not set)'}',
      );
    } catch (e) {
      return 'Chess Auto Prep $kAppVersion — bughouse engine diagnostics\n'
          '$headline\n'
          '(the diagnostic itself failed: $e)';
    }
  }

  /// The report itself, with every fact already gathered.
  ///
  /// Pure and static so the exact text a user will paste can be asserted in a
  /// test on any platform, rather than only being seen when something breaks.
  @visibleForTesting
  static String formatReport({
    required String headline,
    required String executablePath,
    required List<String> argv,
    required String workingDirectory,
    required int? exitCode,
    required bool spoke,
    required List<String> directory,
    required List<DllResolution>? libraries,
    required List<String> stdout,
    required List<String> stderr,
    String? loaderPath,
  }) {
    final out = StringBuffer()
      ..writeln('Chess Auto Prep $kAppVersion — bughouse engine diagnostics')
      ..writeln('Problem     : $headline')
      ..writeln(
        'Exit        : ${exitCode == null ? 'still running when it was given up on' : '$exitCode — ${describeExit(exitCode)}'}',
      )
      ..writeln(
        'Spoke       : ${spoke ? 'yes, the engine printed at least one line' : 'no — it never reached its own startup banner'}',
      )
      ..writeln('OS          : ${Platform.operatingSystemVersion}')
      ..writeln('Engine      : $executablePath')
      ..writeln('Command     : ${argv.join(' ')}')
      ..writeln('Working dir : $workingDirectory');
    if (loaderPath != null) out.writeln('Library path: $loaderPath');

    out
      ..writeln()
      ..writeln('Files beside the engine');
    out.writeln(directory.isEmpty ? '  (none)' : directory.join('\n'));

    if (libraries != null) {
      out
        ..writeln()
        ..writeln('Where Windows resolves each library the engine needs')
        ..writeln(WindowsLoaderCheck.report(libraries));
      final problem = WindowsLoaderCheck.describe(libraries);
      if (problem != null) {
        out
          ..writeln()
          ..writeln('!! $problem');
      }
    }

    out
      ..writeln()
      ..writeln('Engine stderr')
      ..writeln(
        stderr.isEmpty
            ? '  (nothing — which is itself the finding when it also never '
                  'printed to stdout)'
            : stderr.map((l) => '  $l').join('\n'),
      )
      ..writeln()
      ..writeln('Engine stdout')
      ..writeln(
        stdout.isEmpty ? '  (nothing)' : stdout.map((l) => '  $l').join('\n'),
      );
    return out.toString().trimRight();
  }

  /// One line per file in [directory]: its size, the size it should be, and on
  /// Windows the architecture of its image.
  ///
  /// A wrong size is what an interrupted extraction looks like, and Windows
  /// rejects a truncated DLL with the same status it uses for a 32-bit one —
  /// so having both readings side by side is what tells those two apart.
  @visibleForTesting
  static Future<List<String>> describeDirectory(
    String directory,
    Map<String, int> expected,
  ) async {
    final dir = Directory(directory);
    if (!await dir.exists()) return ['  (the directory does not exist)'];
    final lines = <String>[];
    await for (final entry in dir.list(followLinks: false)) {
      if (entry is! File) continue;
      final name = p.basename(entry.path);
      final size = await entry.length();
      final want = expected[name];
      final buffer = StringBuffer(
        '  ${name.padRight(28)}${size.toString().padLeft(12)} bytes',
      );
      if (want != null) {
        buffer.write(size == want ? '  (size ok)' : '  SHOULD BE $want');
      }
      if (Platform.isWindows &&
          (name.toLowerCase().endsWith('.dll') ||
              name.toLowerCase().endsWith('.exe'))) {
        buffer.write(
          '  [${WindowsLoaderCheck.describeMachine(await WindowsLoaderCheck.machineOfFile(entry))}]',
        );
      }
      lines.add(buffer.toString());
    }
    lines.sort();
    return lines;
  }

  void _failPending(String message) {
    for (final c in [_readyCompleter, _uciOkCompleter]) {
      if (c != null && !c.isCompleted) {
        c.completeError(BughouseEngineFailure(message));
      }
    }
    final search = _searchCompleter;
    if (search != null && !search.isCompleted) {
      search.completeError(BughouseEngineFailure(message));
    }
  }

  void _onLine(String line) {
    final text = line.trim();
    if (text.isEmpty) return;

    if (text == 'uciok') {
      _completeOnce(_uciOkCompleter);
      return;
    }
    if (text == 'readyok') {
      _completeOnce(_readyCompleter);
      return;
    }
    if (text.startsWith('id name ')) {
      _name = text.substring('id name '.length).trim();
      return;
    }
    if (text.startsWith('info string backend ')) {
      // "info string backend ONNX Runtime (CPU) model hivemind.onnx batch 8
      //  workers 4 intra-op threads 5"
      final rest = text.substring('info string backend '.length);
      final modelAt = rest.indexOf(' model ');
      _backend = modelAt > 0 ? rest.substring(0, modelAt) : rest;
      _backendDetail = _summariseBackend(rest);
      return;
    }
    if (text.startsWith('bestmove')) {
      _onBestMove(text);
      return;
    }
    if (text.startsWith('info ') && text.contains(' depth ')) {
      final info = _parseInfo(text);
      if (info == null) return;
      final collected = _searchInfos;
      if (collected != null) {
        collected.add(info);
        // Only the tail matters — `lines` keeps the last state of each rank,
        // and the engine prints its MultiPV block immediately before
        // `bestmove`. A ten-minute timeout is the real ceiling otherwise.
        if (collected.length > _maxInfos) {
          collected.removeRange(0, collected.length - _maxInfos);
        }
      }
      if (!_infoController.isClosed) _infoController.add(info);
    }
  }

  void _completeOnce(Completer<void>? completer) {
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  void _onBestMove(String text) {
    final completer = _searchCompleter;
    if (completer == null || completer.isCompleted) return;

    // bestmove (d2d4,pass) ponder (d7d5,d2d4)
    final ponderAt = text.indexOf(' ponder ');
    final bestPart = ponderAt >= 0
        ? text.substring('bestmove '.length, ponderAt)
        : text.substring('bestmove '.length);
    final ponderPart = ponderAt >= 0
        ? text.substring(ponderAt + ' ponder '.length)
        : null;

    completer.complete(
      _SearchResult(
        BughouseJointMove.tryParse(bestPart),
        ponderPart == null ? null : BughouseJointMove.tryParse(ponderPart),
      ),
    );
  }

  BughouseInfo? _parseInfo(String text) {
    final tokens = text.split(RegExp(r'\s+'));
    int depth = 0, nodes = 0, nps = 0, timeMs = 0, scoreCp = 0, multipv = 1;
    int? mateIn;
    final pv = <BughouseJointMove>[];

    for (var i = 0; i < tokens.length; i++) {
      switch (tokens[i]) {
        case 'depth':
          depth = int.tryParse(_at(tokens, i + 1)) ?? depth;
        case 'multipv':
          multipv = int.tryParse(_at(tokens, i + 1)) ?? multipv;
        case 'nodes':
          nodes = int.tryParse(_at(tokens, i + 1)) ?? nodes;
        case 'nps':
          nps = int.tryParse(_at(tokens, i + 1)) ?? nps;
        case 'time':
          timeMs = int.tryParse(_at(tokens, i + 1)) ?? timeMs;
        case 'score':
          // "score cp -230" or "score mate 3"
          switch (_at(tokens, i + 1)) {
            case 'cp':
              scoreCp = int.tryParse(_at(tokens, i + 2)) ?? scoreCp;
            case 'mate':
              mateIn = int.tryParse(_at(tokens, i + 2));
          }
        case 'pv':
          for (final token in tokens.sublist(i + 1)) {
            final move = BughouseJointMove.tryParse(token);
            if (move != null) pv.add(move);
          }
          i = tokens.length;
      }
    }
    if (depth == 0 && pv.isEmpty) return null;
    // The root's unvisited MCTS prior, Q = -1, which the engine prints as
    // `180*tan(-1.56)` = -16671 on the first line of every single search
    // before any node has been evaluated. Folded into the live eval it made
    // the headline number flash -164.41 and empty the bar at the start of
    // every pass. A node count, not the magic value, is what says "nothing has
    // actually been looked at yet".
    if (nodes <= 1) return null;
    return BughouseInfo(
      depth: depth,
      scoreCp: scoreCp,
      nodes: nodes,
      nps: nps,
      timeMs: timeMs,
      multipv: multipv,
      mateIn: mateIn,
      hadTimeAdvantage: _timeAdvantage,
      pv: pv,
    );
  }

  static String _at(List<String> tokens, int index) =>
      index >= 0 && index < tokens.length ? tokens[index] : '';

  /// `4 workers · 5 threads · batch 8` out of the engine's own backend line.
  ///
  /// Each part is optional: a build that stops reporting one of them should
  /// shorten the readout, not print a zero.
  static String _summariseBackend(String rest) {
    final parts = <String>[
      if (_numberAfter(rest, 'workers ') case final n?) '$n workers',
      if (_numberAfter(rest, 'intra-op threads ') case final n?) '$n threads',
      if (_numberAfter(rest, 'batch ') case final n?) 'batch $n',
    ];
    return parts.join(' · ');
  }

  static final _leadingDigits = RegExp(r'^\d+');

  static int? _numberAfter(String text, String key) {
    final at = text.indexOf(key);
    if (at < 0) return null;
    final match = _leadingDigits.firstMatch(text.substring(at + key.length));
    return match == null ? null : int.tryParse(match[0]!);
  }
}

class _SearchResult {
  _SearchResult(this.best, this.ponder);
  final BughouseJointMove? best;
  final BughouseJointMove? ponder;
}

/// What one completed search produced.
class BughouseSearchResult {
  const BughouseSearchResult({
    required this.best,
    required this.ponder,
    required this.infos,
  });

  final BughouseJointMove? best;
  final BughouseJointMove? ponder;
  final List<BughouseInfo> infos;

  BughouseInfo? get lastInfo => infos.isEmpty ? null : infos.last;

  /// The final state of each ranked line, best first.
  ///
  /// The engine re-emits every rank on each deepening, so what matters is the
  /// last `info` seen per `multipv` index — anything earlier is a stale view
  /// of the same line.
  ///
  /// Sorted by score rather than left in the engine's own MultiPV order, which
  /// is an MCTS *visit* count: measured on a real block, ranks 1-5 scored
  /// +0.08, -0.61, -0.38, -0.46, -0.53, so presenting that order as a ranking
  /// contradicts the numbers printed beside it. Rank 1 stays pinned at the
  /// front because it is the line `bestmove` is aligned with — the engine's
  /// solver-aware choice, which is not always its highest score.
  List<BughouseInfo> get lines {
    final byRank = <int, BughouseInfo>{};
    for (final info in infos) {
      byRank[info.multipv] = info;
    }
    final ranks = byRank.keys.toList()..sort();
    final ordered = [for (final rank in ranks) byRank[rank]!];
    if (ordered.length < 2) return ordered;
    final rest = ordered.sublist(1)
      ..sort((a, b) => _strength(b).compareTo(_strength(a)));
    return [ordered.first, ...rest];
  }

  /// How good a line is for the team that was searched. Higher is better; a
  /// mate for us beats every score, a mate against us loses to every score,
  /// and inside each group the faster mate is the more extreme one.
  static double _strength(BughouseInfo info) {
    final mate = info.mateIn;
    if (mate == null) return info.scoreCp.toDouble();
    const huge = 1000000.0;
    return mate > 0 ? huge - mate : -huge - mate;
  }

  /// The line the reported `bestmove` belongs to — rank 1, which the engine
  /// keeps aligned with its solver-aware choice.
  BughouseInfo? get principal {
    final ranked = lines;
    return ranked.isEmpty ? null : ranked.first;
  }
}
