import 'package:chess_auto_prep/services/jobs/repertoire_job.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('terminal statuses stamp completedAt; queued/running do not', () {
    for (final status in JobStatus.values) {
      final job = RepertoireJob(id: 'j', type: JobType.audit, label: 'x');
      job.updateStatus(status);
      expect(job.completedAt != null, status.isTerminal, reason: '$status');
    }
    expect(JobStatus.completed.isTerminal, isTrue);
    expect(JobStatus.paused.isTerminal, isFalse);
  });

  test(
    'registry observer sees the configured running job on first publication',
    () {
      final manager = JobManager();
      addTearDown(manager.dispose);
      var observed = 0;
      manager.addListener(() {
        observed++;
        final job = manager.jobs.single;
        expect(job.status, JobStatus.running);
        expect(job.label, 'Captured chapter');
        expect(job.subtreeFen, 'captured root');
        expect(job.configSnapshot, {'maxPly': 3});
      });
      manager.createJob(
        type: JobType.generation,
        label: 'Captured chapter',
        subtreeFen: 'captured root',
        configSnapshot: {'maxPly': 3},
        status: JobStatus.running,
      );
      expect(observed, 1);
    },
  );

  test('activeJob returns the newest running or paused job of a type', () {
    final manager = JobManager.instance;
    final older = manager.createJob(type: JobType.coverage, label: 'old');
    final newer = manager.createJob(type: JobType.coverage, label: 'new');
    final other = manager.createJob(type: JobType.audit, label: 'audit');
    addTearDown(() {
      for (final job in [older, newer, other]) {
        manager.removeJob(job);
      }
    });

    expect(manager.activeJob(JobType.coverage), isNull);
    older.updateStatus(JobStatus.running);
    expect(manager.activeJob(JobType.coverage), same(older));
    newer.updateStatus(JobStatus.paused);
    expect(manager.activeJob(JobType.coverage), same(newer));
    expect(manager.activeJob(JobType.audit), isNull);
    newer.updateStatus(JobStatus.completed);
    expect(manager.activeJob(JobType.coverage), same(older));
    expect(manager.completedJobs, contains(newer));
    expect(manager.activeJobs, contains(older));
  });

  test('clearCompleted keeps queued and active jobs', () {
    final manager = JobManager.instance;
    final queued = manager.createJob(type: JobType.audit, label: 'queued');
    final running = manager.createJob(type: JobType.audit, label: 'running')
      ..updateStatus(JobStatus.running);
    final failed = manager.createJob(type: JobType.audit, label: 'failed')
      ..fail('boom');
    addTearDown(() {
      for (final job in [queued, running, failed]) {
        manager.removeJob(job);
      }
    });

    manager.clearCompleted();
    expect(manager.jobs, containsAll([queued, running]));
    expect(manager.jobs, isNot(contains(failed)));
    expect(failed.error, 'boom');
  });
}
