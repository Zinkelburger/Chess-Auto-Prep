import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:onnxruntime/onnxruntime.dart';

import '../../chess/fen.dart';
import '../../diagnostics/log.dart';
import 'maia_input.dart';
import 'maia_session.dart';
import 'maia_vocabulary.dart';
import 'move_policy.dart';
import 'move_shares.dart';

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

  /// Inference waits its turn: the wrapper's worker isolate pairs answers
  /// with requests by the order they were sent, so two overlapping runs
  /// could be given each other's numbers.
  Future<void> _turn = Future.value();
  bool _disposed = false;

  @override
  Future<MaiaAnswer> policy(Fen fen, int elo) {
    if (_disposed) return Future.value(const MaiaFailed(_shutDown));
    final answer = _turn.then((_) => _ask(fen, elo));
    _turn = answer.then((_) {}, onError: (Object _) {});
    return answer;
  }

  /// Releases the session. Asking afterwards is answered, not an error.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _session.release();
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
    var outputs = const <OrtValue?>[];
    try {
      // The native call runs in the wrapper's worker isolate; this one only
      // does the encoding and the softmax.
      outputs =
          await _session.runAsync(options, {
            'tokens': board,
            'elo_self': self,
            'elo_oppo': opponent,
          }) ??
          const [];
      // Output 0 is logits_move [1, 4352]; output 1 is the value head, which
      // the repertoire builder does not ask about.
      return outputs.isEmpty ? null : _row(outputs.first?.value);
    } finally {
      board.release();
      self.release();
      opponent.release();
      options.release();
      for (final output in outputs) {
        output?.release();
      }
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
