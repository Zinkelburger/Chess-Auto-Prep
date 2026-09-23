import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:onnxruntime/onnxruntime.dart';

import '../../chess/fen.dart';
import '../../diagnostics/log.dart';
import 'maia_input.dart';
import 'maia_vocabulary.dart';
import 'move_policy.dart';

/// Maia-3, the network that answers how a human of a given rating plays.
///
/// One model serves the whole app: the session holds 45 MB of weights and is
/// the only thing here that is expensive. Inference is serialised, positions
/// go in one at a time, and every answer is either a policy or a sentence
/// saying why there is none.
final class MaiaModel implements MovePolicy {
  MaiaModel._(this._session, this._vocabulary);

  /// The board input as the network declares it.
  static const List<int> _boardShape = [1, 64, 12];
  static const List<int> _ratingShape = [1];

  /// Builds the session off the calling isolate. [model] is the `.onnx`
  /// bytes, [moveVocabulary] the JSON text of `all_moves_maia3.json`.
  ///
  /// Nothing here throws: a build without the runtime, a damaged asset or a
  /// machine the library will not load on all come back as
  /// [MaiaUnavailable], because the app has to be able to say "no opponent
  /// model" and carry on with the rest of the repertoire work.
  static Future<MaiaLoad> load({
    required Uint8List model,
    required String moveVocabulary,
  }) async {
    final vocabulary = MaiaVocabulary.parse(moveVocabulary);
    if (vocabulary == null) {
      log.e('read the Maia move list', 'the text is not a move table');
      return const MaiaUnavailable('The move list this build ships is damaged');
    }
    try {
      OrtEnv.instance.init();
      final address = await Isolate.run(() {
        // Each isolate initialises the runtime for itself.
        OrtEnv.instance.init();
        return createMaiaSession(model);
      });
      return MaiaReady(
        MaiaModel._(OrtSession.fromAddress(address), vocabulary),
      );
    } catch (error) {
      log.e('load the Maia model', error);
      return MaiaUnavailable('Maia could not be loaded: $error');
    }
  }

  final OrtSession _session;
  final MaiaVocabulary _vocabulary;

  /// Inference waits its turn: one run at a time keeps the model on the
  /// one thread it was built with, and lets [dispose] release the session
  /// only once nothing is running on it.
  Future<void> _turn = Future.value();
  bool _disposed = false;

  @override
  Future<MaiaAnswer> policy(Fen fen, int elo) {
    if (_disposed) return Future.value(const MaiaFailed(_shutDown));
    final answer = _turn.then((_) => _ask(fen, elo));
    _turn = answer.then((_) {}, onError: (Object _) {});
    return answer;
  }

  /// Releases the session once the question it may be answering is done.
  /// Asking afterwards is answered, not an error.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_turn.then((_) => _session.release()));
  }

  static const String _shutDown = 'The opponent model has been shut down';

  Future<MaiaAnswer> _ask(Fen fen, int elo) async {
    final input = encodeForMaia(fen, _vocabulary);
    if (input == null) {
      log.w('read a position for Maia', fen.value);
      return const MaiaFailed('That position could not be read');
    }
    if (_disposed) return const MaiaFailed(_shutDown);
    final List<double>? logits;
    try {
      logits = await _infer(input, elo);
    } catch (error) {
      log.e('ask Maia about a position', error);
      return MaiaFailed('Maia could not answer: $error');
    }
    if (logits == null) {
      log.e('ask Maia about a position', 'the answer had an unknown shape');
      return const MaiaFailed(
        'Maia answered in a shape this build cannot read',
      );
    }
    return MaiaPolicy(
      sharesFromLogits(
        logits,
        input.legalMask,
        mirrored: input.mirrored,
        vocabulary: _vocabulary,
      ),
    );
  }

  /// The move head for [input], or null when the model answered in an
  /// unexpected shape. Both ratings are the same number: the builder asks
  /// what a player of this strength plays against one of their own.
  Future<List<double>?> _infer(MaiaInput input, int elo) async {
    final rating = Float32List.fromList([elo.toDouble()]);
    final board = OrtValueTensor.createTensorWithDataList(
      input.tokens,
      _boardShape,
    );
    final self = OrtValueTensor.createTensorWithDataList(rating, _ratingShape);
    final opponent = OrtValueTensor.createTensorWithDataList(
      rating,
      _ratingShape,
    );
    final options = OrtRunOptions();
    try {
      return await _runElsewhere(_session.address, options.address, {
        'tokens': board.address,
        'elo_self': self.address,
        'elo_oppo': opponent.address,
      });
    } finally {
      board.release();
      self.release();
      opponent.release();
      options.release();
    }
  }

  /// The one row of a `[1, n]` output, or a flat `[n]` one, copied out so it
  /// does not outlive the tensor it came from. Null when the value is not
  /// numbers at all.
  static List<double>? _row(Object? value) {
    if (value is! List<Object?>) return null;
    final head = value.isEmpty ? null : value.first;
    final row = head is List<Object?> ? head : value;
    final numbers = <double>[];
    for (final cell in row) {
      if (cell is! num) return null;
      numbers.add(cell.toDouble());
    }
    return numbers;
  }
}

/// Runs the session at [session] on the tensors at [inputs] in an isolate
/// of its own and answers the move head, as [MaiaModel._row] reads it.
///
/// Not the wrapper's `runAsync`: its one worker isolate never answers a run
/// that failed, so the question waits for ever and every later one waits
/// behind it. Here the session, the options and the tensors cross as native
/// addresses — the wrapper's own worker adopts them the same way — the
/// outputs are read and released on the far side, and a failure comes back
/// as the error it is. The encoding and the softmax stay on the caller.
Future<List<double>?> _runElsewhere(
  int session,
  int options,
  Map<String, int> inputs,
) => Isolate.run(() => _run(session, options, inputs));

List<double>? _run(int session, int options, Map<String, int> inputs) {
  final outputs = OrtSession.fromAddress(session)
      .run(OrtRunOptions.fromAddress(options), {
        for (final MapEntry(:key, :value) in inputs.entries)
          key: OrtValueTensor.fromAddress(value),
      });
  try {
    // Output 0 is logits_move [1, 4352]; output 1 is the value head, which
    // the repertoire builder does not ask about.
    return outputs.isEmpty ? null : MaiaModel._row(outputs.first?.value);
  } finally {
    for (final output in outputs) {
      output?.release();
    }
  }
}

sealed class MaiaLoad {
  const MaiaLoad();
}

final class MaiaReady extends MaiaLoad {
  const MaiaReady(this.model);

  final MaiaModel model;
}

final class MaiaUnavailable extends MaiaLoad {
  const MaiaUnavailable(this.reason);

  final String reason;
}

typedef _Status = Pointer<Void>;
typedef _Handle = Pointer<Void>;

/// The five ONNX Runtime C entry points the Dart wrapper does not reach.
typedef _SessionCalls = ({
  _Status Function(Pointer<_Handle>) createOptions,
  _Status Function(_Handle, int) setIntraOpThreads,
  _Status Function(_Handle) disableMemPattern,
  _Status Function(_Handle, _Handle, int, _Handle, Pointer<_Handle>)
  createSession,
  void Function(_Handle) releaseOptions,
});

/// Builds the ONNX session for [model] and returns its native address.
///
/// Two session options decide whether the opponent model is reproducible,
/// and the Dart wrapper exposes neither, so they are set through the C API
/// before the session exists. Memory patterns are off because with this
/// runtime and this model the first run and every later run otherwise
/// disagree in the fourth decimal — 0.9220 against 0.9206 for the same
/// position (docs/PARALLEL_EXPECTIMAX.md) — and a tree built from numbers
/// that change on the second ask cannot be reproduced or compared. One
/// intra-op thread is the other half of that: the runtime's thread pool
/// sums partial results in whatever order the threads finish.
///
/// Meant to be called inside `Isolate.run`. Parsing 45 MB of graph is one
/// long synchronous native call, which would stop the app dead; the session
/// outlives the isolate and is adopted with `OrtSession.fromAddress`.
int createMaiaSession(Uint8List model) {
  final calls = _bind();
  final options = calloc<_Handle>();
  final session = calloc<_Handle>();
  final buffer = calloc<Uint8>(model.length);
  void check(_Status status) => OrtStatus.checkOrtStatus(status.cast());
  try {
    check(calls.createOptions(options));
    check(calls.setIntraOpThreads(options.value, 1));
    check(calls.disableMemPattern(options.value));
    buffer.asTypedList(model.length).setAll(0, model);
    check(
      calls.createSession(
        OrtEnv.instance.ptr.cast(),
        buffer.cast(),
        model.length,
        options.value,
        session,
      ),
    );
    return session.value.address;
  } finally {
    if (options.value != nullptr) calls.releaseOptions(options.value);
    calloc.free(buffer);
    calloc.free(session);
    calloc.free(options);
  }
}

_SessionCalls _bind() {
  final api = OrtEnv.instance.ortApiPtr.ref;
  return (
    createOptions:
        api.CreateSessionOptions.cast<
              NativeFunction<_Status Function(Pointer<_Handle>)>
            >()
            .asFunction(),
    setIntraOpThreads:
        api.SetIntraOpNumThreads.cast<
              NativeFunction<_Status Function(_Handle, Int32)>
            >()
            .asFunction(),
    disableMemPattern:
        api.DisableMemPattern.cast<NativeFunction<_Status Function(_Handle)>>()
            .asFunction(),
    createSession:
        api.CreateSessionFromArray.cast<
              NativeFunction<
                _Status Function(
                  _Handle,
                  _Handle,
                  IntPtr,
                  _Handle,
                  Pointer<_Handle>,
                )
              >
            >()
            .asFunction(),
    releaseOptions:
        api.ReleaseSessionOptions.cast<NativeFunction<Void Function(_Handle)>>()
            .asFunction(),
  );
}

/// What a legal move the network produced no number for is scored. Low
/// enough that the softmax makes it zero without making the others NaN.
const double _missingLogit = -9999.0;

/// The network's move output as a share per legal move, most likely first.
///
/// Softmax over the masked entries only, so the moves that can actually be
/// played share the whole 1.0 between them: a position with two legal moves
/// gives two numbers, not 4352. Shares are what the builder needs, because
/// the question is always "how much of the opponent's play goes down this
/// move", never "what is this move worth".
///
/// Worked example: two legal moves with logits 3.0 and 1.0 come back as
/// 0.881 and 0.119, because e^2 : e^0 is about 7.4 : 1.
///
/// When the position was [mirrored] to put White on the move, the names are
/// mirrored back to the board the caller asked about.
Map<String, double> sharesFromLogits(
  List<double> logits,
  Float32List legalMask, {
  required bool mirrored,
  required MaiaVocabulary vocabulary,
}) {
  final indices = <int>[];
  final scores = <double>[];
  for (var i = 0; i < legalMask.length; i++) {
    if (legalMask[i] <= 0) continue;
    indices.add(i);
    scores.add(i < logits.length ? logits[i] : _missingLogit);
  }
  if (indices.isEmpty) return const {};

  // The highest score is taken out before the exponential so a large logit
  // cannot overflow; it cancels in the division.
  final highest = scores.reduce(math.max);
  final weights = [for (final score in scores) math.exp(score - highest)];
  final total = weights.reduce((a, b) => a + b);
  final shares = <MapEntry<String, double>>[
    for (var i = 0; i < indices.length; i++)
      MapEntry(
        _nameOf(vocabulary, indices[i], mirrored: mirrored),
        weights[i] / total,
      ),
  ]..sort((a, b) => b.value.compareTo(a.value));
  return Map.fromEntries(shares);
}

String _nameOf(MaiaVocabulary vocabulary, int index, {required bool mirrored}) {
  final name = vocabulary.nameAt(index);
  return mirrored ? mirrorUci(name) : name;
}
