import '../repositories/repertoire_document_repository.dart';

/// The acknowledged originals belong to one loaded chapter. Retained callbacks
/// keep this context, even after a different chapter is displayed.
class RepertoireLineEditContext {
  RepertoireLineEditContext(this.path, Map<String, String> originals)
    : _originals = Map.of(originals);
  final String path;
  final Map<String, String> _originals;
}

/// Immutable pending work, suitable for inspection and recovery serialization.
/// Captured originals remain authority; a retry never refreshes them from disk.
class RepertoireLineDraft {
  const RepertoireLineDraft({
    required this.path,
    required this.lineId,
    required this.original,
    required this.content,
    required this.error,
  });
  final String path;
  final String lineId;
  final String original;
  final String content;
  final Object? error;
}

class _Attempt {
  _Attempt(this.content);
  final String content;
  Object? error;
}

/// Serial line persistence with independent pending drafts for each bound line.
/// A success cannot clear another line's failure. Superseded queued attempts
/// advance the acknowledged baseline but cannot consume a newer draft.
class RepertoireLineEdits {
  RepertoireLineEdits(this.documents);
  final RepertoireDocumentRepository documents;
  Future<void> _tail = Future.value();
  final _pending = <(RepertoireLineEditContext, String), _Attempt>{};
  int _revision = 0;
  int get revision => _revision;

  List<RepertoireLineDraft> get drafts => List.unmodifiable([
    for (final entry in _pending.entries)
      RepertoireLineDraft(
        path: entry.key.$1.path,
        lineId: entry.key.$2,
        original: entry.key.$1._originals[entry.key.$2]!,
        content: entry.value.content,
        error: entry.value.error,
      ),
  ]);

  /// Bind a synthesized/appended line only if this context has no original yet.
  void bind(
    RepertoireLineEditContext context,
    String lineId,
    String original,
  ) => context._originals.putIfAbsent(lineId, () => original);

  Future<String?> save(
    RepertoireLineEditContext context,
    String lineId,
    String content,
  ) {
    if (!context._originals.containsKey(lineId)) {
      throw StateError('A line save requires its loaded original');
    }
    final key = (context, lineId);
    final attempt = _Attempt(content);
    _pending[key] = attempt;
    _revision++;
    final result = _tail.then((_) async {
      try {
        final saved = await documents.updateLineContent(
          context.path,
          lineId,
          content,
          expectedContent: context._originals[lineId]!,
        );
        if (saved == null) {
          attempt.error = StateError('The original line is unavailable.');
        } else {
          context._originals[lineId] = saved;
          if (identical(_pending[key], attempt)) _pending.remove(key);
        }
        return saved;
      } catch (error) {
        attempt.error = error;
        rethrow;
      } finally {
        _revision++;
      }
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> flush() async {
    // Include edits enqueued while an earlier write was being awaited.
    Future<void> observed;
    do {
      observed = _tail;
      await observed;
    } while (!identical(observed, _tail));
    if (_pending.isNotEmpty) {
      throw StateError('Could not save ${_pending.length} pending line edits.');
    }
  }
}
