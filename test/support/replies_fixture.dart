import 'package:chess_auto_prep/engines/maia/move_policy.dart';
import 'package:chess_auto_prep/storage/settings_store.dart';
import 'package:chess_auto_prep/workspace/document_session.dart';
import 'package:chess_auto_prep/workspace/gap_hunt.dart';
import 'package:chess_auto_prep/workspace/replies.dart';

import 'scripted_files.dart';
import 'scripted_store.dart';

/// The Replies table and the gap hunt over one session, sharing one model,
/// as the app wires them. With no [answers], no other chapter answers
/// anything.
final class RepliesFixture {
  factory RepliesFixture(
    DocumentSession session, {
    required MovePolicy policy,
    required SettingsStore settings,
    RepertoireAnswers? answers,
  }) {
    final model = ReplyModel(policy: policy, settings: settings);
    final gaps = GapHunt(
      session: session,
      model: model,
      settings: settings,
      answers:
          answers ??
          RepertoireAnswers(
            files: ScriptedFiles(),
            documents: ScriptedDocumentStore(),
          ),
    );
    final replies = Replies(
      session: session,
      model: model,
      settings: settings,
      gaps: gaps,
    );
    return RepliesFixture._(gaps, replies);
  }

  RepliesFixture._(this.gaps, this.replies);

  final GapHunt gaps;
  final Replies replies;

  /// The table first: it listens to the hunt.
  void dispose() {
    replies.dispose();
    gaps.dispose();
  }
}
