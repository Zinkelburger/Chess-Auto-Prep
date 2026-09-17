import 'dart:io';

import 'package:chess_auto_prep/chess_core/moves/tree_path.dart';
import 'package:chess_auto_prep/features/studies/controllers/study_controller.dart';
import 'package:chess_auto_prep/screens/study_screen.dart';
import 'package:chess_auto_prep/services/storage/app_paths.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../test/support/large_study_fixture.dart';
import 'helpers/tactics_helpers.dart';

/// Run using `scripts/ci.sh profile`. Debug measurements cannot pass this gate.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('STATE-02 profile-mode large document baseline', (tester) async {
    expect(kProfileMode, isTrue, reason: 'Use scripts/ci.sh profile');
    expect(Platform.environment['XDG_DATA_HOME'], contains('/profile/'));
    await pumpApp(tester);
    await switchToMode(tester, 'Study');
    final study = tester
        .element(find.byType(StudyScreen))
        .read<StudyController>();
    final directory = await Directory(
      p.join((await AppPaths.supportDirectory()).path, 'renewal-performance'),
    ).create(recursive: true);
    final file = File(p.join(directory.path, 'Course.pgn'));
    await file.writeAsString(largeStudyPgn());
    final timings = <String, Object>{};
    binding.reportData = {
      'scope': 'Linux profile; 20000 annotated nodes; two CPU runner',
    };
    final watch = Stopwatch()..start();
    await study.openStudy(file.path);
    final loadMicros = watch.elapsedMicroseconds;
    await tester.pumpAndSettle();
    timings['open_and_receive_us'] = loadMicros;
    timings['open_and_first_frame_us'] = watch.elapsedMicroseconds;
    expect(study.tree.roots, hasLength(100));
    // Warm the projection/render path before measuring repeated navigation.
    study.jump(TreePath.from([99, ...List.filled(199, 0)]));
    await tester.pumpAndSettle();
    final rssBefore = ProcessInfo.currentRss;
    final commands = <int>[];
    await binding.watchPerformance(() async {
      for (var i = 0; i < 30; i++) {
        watch.reset();
        study.jump(TreePath.from([i % 100, ...List.filled(199, 0)]));
        commands.add(watch.elapsedMicroseconds);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 40));
      }
    }, reportKey: 'navigation_frames');
    commands.sort();
    timings['navigation_command_p95_us'] =
        commands[(commands.length * .95).ceil() - 1];
    final edits = <int>[];
    await binding.watchPerformance(() async {
      for (var i = 0; i < 30; i++) {
        final previous = study.cursorComment;
        watch.reset();
        study.setComment(study.path, 'Profile edit $i');
        expect(study.tree.roots, hasLength(100));
        edits.add(watch.elapsedMicroseconds);
        await tester.pump();
        study.setComment(study.path, previous);
        await tester.pump(const Duration(milliseconds: 40));
      }
    }, reportKey: 'edit_frames');
    edits.sort();
    timings['edit_and_projection_p95_us'] =
        edits[(edits.length * .95).ceil() - 1];
    timings['rss_before_navigation_bytes'] = rssBefore;
    timings['rss_after_navigation_bytes'] = ProcessInfo.currentRss;
    timings['rss_growth_bytes'] = ProcessInfo.currentRss - rssBefore;
    binding.reportData!['measurements'] = timings;
    binding.reportData!['budgets'] = {
      'open_and_receive_us': 5000000,
      'navigation_command_p95_us': 50000,
      'edit_and_projection_p95_us': 50000,
      'frame_build_p99_ms': 32,
      'rss_growth_bytes': 64 * 1024 * 1024,
    };
    // The initial bounded-host acceptance budgets are recorded before running.
    // Frame/GC observations are retained even when a command budget fails.
    expect(loadMicros, lessThanOrEqualTo(5000000));
    expect(timings['navigation_command_p95_us'], lessThanOrEqualTo(50000));
    expect(timings['edit_and_projection_p95_us'], lessThanOrEqualTo(50000));
    expect(timings['rss_growth_bytes'], lessThanOrEqualTo(64 * 1024 * 1024));
    for (final key in ['navigation_frames', 'edit_frames']) {
      final frames = binding.reportData![key] as Map<String, dynamic>;
      expect(frames['frame_count'], greaterThan(0));
      expect(
        frames['99th_percentile_frame_build_time_millis'],
        lessThanOrEqualTo(32),
        reason: key,
      );
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
