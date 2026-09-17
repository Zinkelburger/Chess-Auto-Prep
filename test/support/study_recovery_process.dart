// Subprocess fixture: the parent kills this process after durable acknowledgement.
import 'dart:io';
import 'package:chess_auto_prep/infrastructure/studies/file_study_recovery_store.dart';
import 'package:chess_auto_prep/features/studies/models/study_workspace_snapshot.dart';

Future<void> main(List<String> args) async {
  final store = FileStudyRecoveryStore(
    directory: () async => Directory(args.single),
  );
  await store.write(
    StudyWorkspaceSnapshot(
      name: 'Killed session',
      path: '',
      content: '[Event "Killed"]\n\n1. e4 e5 *',
      dirty: true,
    ),
  );
  stdout.writeln('checkpoint-ready');
  await stdin.drain<void>();
  await store.close();
}
