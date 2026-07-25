/// One place recording the ask-once questions the user has already answered.
///
/// Any prompt of the form "we noticed X — want us to do Y?" should be asked
/// exactly once per thing it applies to, and be inspectable afterwards. That
/// means a real file next to the user's other data
/// (`~/Documents/asked_questions.json`) rather than an invisible
/// SharedPreferences key per feature:
///
/// ```json
/// {
///   "version": 1,
///   "answers": {
///     "chapterLayout": {
///       "/home/me/repertoires/Colle1/Main.pgn": {
///         "answer": true,
///         "askedUtc": "2026-07-24T18:03:11.000Z",
///         "note": "a course export · 26 chapters"
///       }
///     }
///   }
/// }
/// ```
///
/// Delete the file (or one entry) and every question is asked afresh — which
/// is also how "ask me again" is implemented.
library;

import 'dart:convert';

import '../utils/log.dart';
import 'storage/storage_factory.dart';

/// Ids of the ask-once questions. Keep them here so the file stays readable
/// and two features can never collide on a key.
abstract final class AskedQuestion {
  /// "Looks like a course export — sort it into chapters?", per repertoire
  /// or study file.
  static const chapterLayout = 'chapterLayout';
}

/// A recorded answer plus enough context to make the file self-explanatory.
class AskedQuestionAnswer {
  final bool answer;
  final DateTime askedUtc;

  /// Human-readable reminder of what was proposed, for whoever opens the
  /// file later ("a course export · 26 chapters").
  final String? note;

  const AskedQuestionAnswer({
    required this.answer,
    required this.askedUtc,
    this.note,
  });

  Map<String, dynamic> toJson() => {
    'answer': answer,
    'askedUtc': askedUtc.toIso8601String(),
    if (note != null && note!.isNotEmpty) 'note': note,
  };

  static AskedQuestionAnswer? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final answer = raw['answer'];
    if (answer is! bool) return null;
    return AskedQuestionAnswer(
      answer: answer,
      askedUtc:
          DateTime.tryParse(raw['askedUtc'] as String? ?? '')?.toUtc() ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      note: raw['note'] as String?,
    );
  }
}

class AskedQuestionsStore {
  AskedQuestionsStore({String fileName = defaultFileName})
    : _fileName = fileName;

  static const defaultFileName = 'asked_questions.json';
  static const _version = 1;

  final String _fileName;

  /// questionId → subject (usually a file path) → answer.
  Map<String, Map<String, AskedQuestionAnswer>>? _cache;

  /// Subject used when a question applies to the app as a whole rather than
  /// to one file.
  static const globalSubject = '*';

  /// The stored answer, or null when this question has never been answered
  /// for [subject].
  Future<AskedQuestionAnswer?> answerFor(
    String questionId, {
    String subject = globalSubject,
  }) async {
    final all = await _loadAll();
    return all[questionId]?[subject];
  }

  /// Convenience for the common "have they said yes or no?" check.
  Future<bool?> boolAnswerFor(
    String questionId, {
    String subject = globalSubject,
  }) async => (await answerFor(questionId, subject: subject))?.answer;

  /// Record the user's answer so the question is never asked again for
  /// [subject].
  Future<void> record(
    String questionId, {
    String subject = globalSubject,
    required bool answer,
    String? note,
    DateTime? askedUtc,
  }) async {
    final all = await _loadAll();
    (all[questionId] ??= {})[subject] = AskedQuestionAnswer(
      answer: answer,
      askedUtc: askedUtc?.toUtc() ?? DateTime.now().toUtc(),
      note: note,
    );
    await _save(all);
  }

  /// Forget an answer, so the question is asked again next time. Pass no
  /// [subject] to forget every subject of [questionId].
  Future<void> forget(String questionId, {String? subject}) async {
    final all = await _loadAll();
    if (subject == null) {
      if (all.remove(questionId) == null) return;
    } else {
      final answers = all[questionId];
      if (answers == null || answers.remove(subject) == null) return;
      if (answers.isEmpty) all.remove(questionId);
    }
    await _save(all);
  }

  /// Drops the in-memory copy; the next read re-reads the file. Used when
  /// something outside this store may have rewritten it.
  void invalidateCache() => _cache = null;

  Future<Map<String, Map<String, AskedQuestionAnswer>>> _loadAll() async {
    final cached = _cache;
    if (cached != null) return cached;

    final parsed = <String, Map<String, AskedQuestionAnswer>>{};
    try {
      final raw = await StorageFactory.instance.readFile(_fileName);
      if (raw != null && raw.trim().isNotEmpty) {
        final decoded = jsonDecode(raw);
        final answers = decoded is Map ? decoded['answers'] : null;
        if (answers is Map) {
          for (final entry in answers.entries) {
            final subjects = entry.value;
            if (subjects is! Map) continue;
            final bySubject = <String, AskedQuestionAnswer>{};
            for (final subject in subjects.entries) {
              final answer = AskedQuestionAnswer.fromJson(subject.value);
              if (answer != null) bySubject['${subject.key}'] = answer;
            }
            if (bySubject.isNotEmpty) parsed['${entry.key}'] = bySubject;
          }
        }
      }
    } catch (e) {
      // A corrupt file must never block a prompt — worst case we ask again.
      log.e('Could not read $_fileName: $e');
    }
    return _cache = parsed;
  }

  Future<void> _save(Map<String, Map<String, AskedQuestionAnswer>> all) async {
    _cache = all;
    try {
      final encoded = const JsonEncoder.withIndent('  ').convert({
        'version': _version,
        'answers': {
          for (final entry in all.entries)
            entry.key: {
              for (final subject in entry.value.entries)
                subject.key: subject.value.toJson(),
            },
        },
      });
      await StorageFactory.instance.writeFile(_fileName, encoded);
    } catch (e) {
      log.e('Could not save $_fileName: $e');
    }
  }
}
