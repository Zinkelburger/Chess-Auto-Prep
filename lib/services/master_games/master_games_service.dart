/// App-scoped owner of the master-games database: settings, coverage stats,
/// the TWIC sync job, and the shared query connection the generator and
/// screens read from.
///
/// The sync walks TWIC issue numbers from the configured start issue to the
/// newest published one, downloading each zip and importing it in an
/// isolate ([importPgnIntoMasterGames]); progress shows in the Jobs pane as
/// a resumable job — every finished issue is on disk, so stopping and
/// re-running carries on where it left off.
library;

import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../utils/number_format.dart';
import '../../utils/safe_change_notifier.dart';
import '../jobs/repertoire_job.dart';
import '../storage/sqlite_recovery.dart';
import 'master_book_rebuild.dart';
import 'master_games_db.dart';
import 'master_games_importer.dart';
import 'twic_client.dart';

/// Default depth of a first download, in years of TWIC issues.
const int kMasterGamesDefaultYears = 5;

class MasterGamesService extends ChangeNotifier with SafeChangeNotifier {
  MasterGamesService({
    TwicClient Function()? clientFactory,
    Future<String> Function()? dbPathProvider,
  }) : _clientFactory = clientFactory ?? TwicClient.new,
       _dbPathProvider = dbPathProvider ?? MasterGamesDb.defaultPath;

  static final MasterGamesService instance = MasterGamesService();

  static const _keyStartIssue = 'master_games.start_issue';
  static const _keyUseInGeneration = 'master_games.use_in_generation';
  static const _keyPromptDismissed = 'master_games.prompt_dismissed';
  static const _keyAutoSync = 'master_games.auto_sync';
  static const _keyLastCheck = 'master_games.last_check_ms';

  /// Minimum gap between automatic checks, so a late TWIC issue is not
  /// probed on every launch.
  static const Duration autoSyncInterval = Duration(hours: 20);

  final TwicClient Function() _clientFactory;
  final Future<String> Function() _dbPathProvider;

  bool _loaded = false;
  int? _startIssue;
  bool _useInGeneration = true;
  bool _promptDismissed = false;
  bool _autoSync = true;
  DateTime? _lastCheck;

  MasterGamesStats? _stats;
  MasterGamesDb? _db;
  String? _dbPath;

  // Sync state.
  bool _syncing = false;
  bool _rebuilding = false;
  bool _cancelRebuild = false;
  bool _cancelRequested = false;
  RepertoireJob? _job;
  String _status = '';
  double _fraction = 0;
  String? _lastError;
  TwicClient? _client;
  Completer<void>? _syncDone;

  bool get isLoaded => _loaded;

  /// First TWIC issue the sync downloads (default: ~5 years back).
  int get startIssue =>
      _startIssue ?? twicIssueYearsBack(kMasterGamesDefaultYears);

  /// Whether the generator should use the database for opponent priors,
  /// model games and "improves on" citations when it has games.
  bool get useInGeneration => _useInGeneration;

  /// The user dismissed the "download master games?" prompt.
  bool get promptDismissed => _promptDismissed;

  /// Check for new TWIC issues automatically at launch once the database
  /// exists (TWIC publishes on Mondays; the check runs at most once per
  /// [autoSyncInterval]).
  bool get autoSync => _autoSync;

  /// When the last automatic or manual check ran.
  DateTime? get lastCheck => _lastCheck;

  MasterGamesStats? get stats => _stats;
  bool get hasGames => (_stats?.games ?? 0) > 0;

  /// True when the generator should consult the database.
  bool get isAvailableForGeneration => _useInGeneration && hasGames;

  bool get isSyncing => _syncing;

  /// Whether the classical index (v4's per-row classical counts and the
  /// classical citations) is being rebuilt.
  bool get isRebuildingClassical => _rebuilding;

  /// Whether every book row's classical-only counts are trustworthy.  False
  /// on a database imported before v4 until [rebuildClassicalIndex] has run
  /// to the end; true when there is no database at all, since there is
  /// nothing to rebuild.
  bool get classicalCountsComplete => _db?.classicalCountsComplete ?? true;

  /// Completes when the sync in flight ends — finished, cancelled or
  /// failed.  A caller that wants to wait for a sync it did not start (the
  /// generator's pre-build download joins a startup auto-sync rather than
  /// queueing a second one) awaits this; it is already complete when
  /// nothing is running.
  Future<void> get syncCompletion => _syncDone?.future ?? Future<void>.value();
  String get status => _status;
  double get fraction => _fraction;
  String? get lastError => _lastError;

  /// Shared query connection (null until the database exists).  Callers in
  /// the UI isolate use it directly; reads are indexed and sub-millisecond.
  MasterGamesDb? get db => _db;

  /// Path of the database file, for isolates that open their own connection.
  String? get dbPath => _dbPath;

  Future<void> load() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    _startIssue = prefs.getInt(_keyStartIssue);
    _useInGeneration = prefs.getBool(_keyUseInGeneration) ?? true;
    _promptDismissed = prefs.getBool(_keyPromptDismissed) ?? false;
    _autoSync = prefs.getBool(_keyAutoSync) ?? true;
    final lastMs = prefs.getInt(_keyLastCheck);
    _lastCheck = lastMs == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(lastMs);
    _loaded = true;
    await refreshStats();
  }

  Future<void> setAutoSync(bool value) async {
    if (_autoSync == value) return;
    _autoSync = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyAutoSync, value);
  }

  /// Whether an automatic check is due: the database exists, auto-sync is
  /// on, a new weekly issue should be out by now, and the last check is
  /// older than [autoSyncInterval].
  bool isAutoSyncDue({DateTime? now}) {
    if (!_loaded || !_autoSync || _syncing || !hasGames) return false;
    final t = now ?? DateTime.now();
    final last = _lastCheck;
    if (last != null && t.difference(last) < autoSyncInterval) return false;
    final newest = _stats?.lastIssue ?? 0;
    return twicIssueEstimateFor(t) > newest;
  }

  /// Run [sync] when [isAutoSyncDue]; called once at launch after [load].
  Future<void> autoSyncIfDue() async {
    if (!isAutoSyncDue()) return;
    await sync();
  }

  Future<void> _recordCheck() async {
    _lastCheck = DateTime.now();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyLastCheck, _lastCheck!.millisecondsSinceEpoch);
  }

  Future<void> setStartIssue(int issue) async {
    final clamped = issue < kTwicFirstPgnIssue ? kTwicFirstPgnIssue : issue;
    if (_startIssue == clamped) return;
    _startIssue = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyStartIssue, clamped);
  }

  Future<void> setUseInGeneration(bool value) async {
    if (_useInGeneration == value) return;
    _useInGeneration = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyUseInGeneration, value);
  }

  Future<void> dismissPrompt() async {
    if (_promptDismissed) return;
    _promptDismissed = true;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyPromptDismissed, true);
  }

  /// Open the cache, recovering from a damaged file by moving it aside.
  /// This database is derived data — every game in it can be downloaded
  /// again from TWIC — so a corrupt file is worth trading for an empty one
  /// the user can re-sync, rather than an error every screen has to carry.
  MasterGamesDb _openDb(String path) => openSqlite(
    path,
    () => MasterGamesDb.open(path),
    label: 'Master games database',
  );

  /// Re-read coverage from the database file (cheap: three COUNTs).
  Future<void> refreshStats() async {
    try {
      final path = _dbPath ??= await _dbPathProvider();
      _db ??= _openDb(path);
      _stats = _db!.stats();
    } catch (e) {
      _lastError = 'Master games database unavailable: $e';
      _stats = null;
    }
    notifyListeners();
  }

  /// Download and import every TWIC issue from [startIssue] (or [fromIssue])
  /// to the newest published one that is not already in the database.
  Future<void> sync({int? fromIssue}) async {
    if (_syncing) return;
    if (!_loaded) await load();
    _syncing = true;
    _syncDone = Completer<void>();
    _cancelRequested = false;
    _lastError = null;
    _fraction = 0;
    _status = 'Checking The Week in Chess…';
    final job = _job = JobManager.instance.createJob(
      type: JobType.masterGames,
      label: 'Master games (TWIC)',
    );
    job.resumable = true;
    job.onCancel = cancel;
    job.updateStatus(JobStatus.running);
    job.updateProgress(JobProgress(message: _status));
    notifyListeners();

    final client = _client = _clientFactory();
    var cancelled = false;
    try {
      final path = _dbPath ??= await _dbPathProvider();
      _db ??= _openDb(path);
      final have = _db!.importedIssues();
      final start = fromIssue ?? startIssue;
      final probeFrom = have.isEmpty
          ? twicIssueEstimateFor(DateTime.now()) - 2
          : have.reduce((a, b) => a > b ? a : b) + 1;
      final latest = await client.latestIssue(
        from: probeFrom < start ? start : probeFrom,
      );
      if (latest == null) {
        throw const TwicDownloadException(
          0,
          'could not reach theweekinchess.com — check your connection',
        );
      }
      await _recordCheck();
      final todo = [
        for (var n = start; n <= latest; n++)
          if (!have.contains(n)) n,
      ];
      if (todo.isEmpty) {
        _status = 'Up to date (issue $latest).';
        job.updateProgress(JobProgress(fraction: 1, message: _status));
        return;
      }

      var done = 0;
      var gamesAdded = 0;

      // Download and import are pipelined: issue N+1 is fetched while
      // issue N imports in its isolate, so the wall-clock is the slower of
      // the two rather than their sum.  A failed download (a gap in the
      // numbering, rare) is a null — skipped, never an unhandled error on a
      // future nobody is awaiting anymore after a cancel.
      Future<String?> fetch(int issue) async {
        try {
          return await client.fetchIssuePgn(issue);
        } on TwicDownloadException catch (e) {
          debugPrint('MasterGames: skipping $e');
          return null;
        } catch (e) {
          if (_cancelRequested) return null;
          rethrow;
        }
      }

      var pending = fetch(todo.first);
      for (var i = 0; i < todo.length; i++) {
        final issue = todo[i];
        if (_cancelRequested) {
          cancelled = true;
          break;
        }
        _status = 'TWIC $issue — downloading… (${done + 1}/${todo.length})';
        _fraction = done / todo.length;
        job.updateProgress(
          JobProgress(
            fraction: _fraction,
            message: _status,
            nodesProcessed: done,
            totalNodes: todo.length,
          ),
        );
        notifyListeners();

        final pgn = await pending;
        if (_cancelRequested) {
          cancelled = true;
          break;
        }
        if (i + 1 < todo.length) pending = fetch(todo[i + 1]);
        if (pgn == null) {
          done++;
          continue;
        }

        _status = 'TWIC $issue — importing… (${done + 1}/${todo.length})';
        job.updateProgress(
          JobProgress(
            fraction: _fraction,
            message: _status,
            nodesProcessed: done,
            totalNodes: todo.length,
          ),
        );
        notifyListeners();

        final request = MasterGamesImportRequest(
          dbPath: path,
          pgnText: pgn,
          twicIssue: issue,
        );
        final result = await _importInIsolate(request);
        gamesAdded += result.gamesImported;
        done++;
      }
      // A cancel may leave a prefetch in flight; let it finish (or fail)
      // quietly before the client is closed under it.
      unawaited(pending.catchError((_) => null));

      _stats = _db!.stats();
      _fraction = cancelled ? done / todo.length : 1;
      _status = cancelled
          ? 'Paused after $done of ${todo.length} issues '
                '($gamesAdded games added).'
          : 'Imported $done issues, $gamesAdded games.';
      job.updateProgress(
        JobProgress(
          fraction: _fraction,
          message: _status,
          nodesProcessed: done,
          totalNodes: todo.length,
        ),
      );
    } catch (e) {
      _lastError = 'Master games sync failed: $e';
      _status = _lastError!;
      job.fail(_lastError!);
    } finally {
      client.close();
      _client = null;
      _syncing = false;
      _job = null;
      _syncDone?.complete();
      _syncDone = null;
      if (job.isActive) {
        job.updateStatus(cancelled ? JobStatus.cancelled : JobStatus.completed);
      }
      // Stats may have changed even on failure (issues before the error).
      try {
        _stats = _db?.stats();
      } catch (_) {}
      notifyListeners();
    }
  }

  /// Kept out of [sync]'s scope on purpose: a closure created there would
  /// capture the whole enclosing context — including `this` and its FFI
  /// database handle, which cannot cross an isolate boundary.
  static Future<MasterGamesImportResult> _importInIsolate(
    MasterGamesImportRequest request,
  ) => Isolate.run(() => importPgnIntoMasterGames(request));

  /// Games replayed per isolate hop of [rebuildClassicalIndex].  Large enough
  /// that reopening the database per hop is noise, small enough that
  /// progress moves and a cancel lands within seconds.
  static const int classicalRebuildChunk = 5000;

  /// Replay the classical games into the book's classical columns — the
  /// citations and the classical-only counts — for a database imported
  /// before those columns existed.
  ///
  /// Runs in chunks on a worker isolate, each opening its own connection,
  /// with progress reported between them as a job.  A rebuild and a sync
  /// both write the book, so neither starts while the other runs.
  Future<void> rebuildClassicalIndex() async {
    if (_rebuilding || _syncing) return;
    if (!_loaded) await load();
    final path = _dbPath;
    final db = _db;
    if (path == null || db == null) return;
    _rebuilding = true;
    _cancelRebuild = false;
    _lastError = null;
    final total = classicalCitationProgress(db).classical;
    final job = JobManager.instance.createJob(
      type: JobType.masterGames,
      label: 'Classical index (TWIC)',
    );
    job.onCancel = cancelRebuild;
    job.updateStatus(JobStatus.running);
    _status = 'Indexing classical games…';
    _fraction = 0;
    job.updateProgress(JobProgress(message: _status));
    notifyListeners();

    var scanned = 0;
    var afterId = 0;
    var cancelled = false;
    try {
      while (true) {
        final chunk = await _rebuildChunkInIsolate(path, afterId);
        scanned += chunk.gamesScanned;
        afterId = chunk.lastId;
        _fraction = total == 0 ? 1 : (scanned / total).clamp(0, 1);
        _status =
            'Indexed ${_thousands(scanned)} of ${_thousands(total)} '
            'classical games';
        job.updateProgress(JobProgress(fraction: _fraction, message: _status));
        notifyListeners();
        if (chunk.done) break;
        if (_cancelRequestedForRebuild) {
          cancelled = true;
          break;
        }
      }
      _status = cancelled
          ? 'Classical index stopped — run it again to finish'
          : 'Classical index built';
    } catch (e) {
      _lastError = 'Classical index failed: $e';
      _status = _lastError!;
    } finally {
      _rebuilding = false;
      if (job.isActive) {
        job.updateStatus(cancelled ? JobStatus.cancelled : JobStatus.completed);
      }
      notifyListeners();
    }
  }

  bool get _cancelRequestedForRebuild => _cancelRebuild;

  void cancelRebuild() {
    if (_rebuilding) _cancelRebuild = true;
  }

  static Future<ClassicalCitationRebuild> _rebuildChunkInIsolate(
    String path,
    int afterId,
  ) => Isolate.run(() async {
    final db = MasterGamesDb.open(path);
    try {
      return await rebuildClassicalCitations(
        db,
        afterId: afterId,
        maxGames: classicalRebuildChunk,
      );
    } finally {
      db.close();
    }
  });

  static String _thousands(int n) => formatThousands(n);

  void cancel() {
    if (!_syncing) return;
    _cancelRequested = true;
    _status = 'Stopping after the current issue…';
    _job?.updateProgress(JobProgress(fraction: _fraction, message: _status));
    notifyListeners();
  }

  @override
  void dispose() {
    _client?.close();
    _db?.close();
    super.dispose();
  }
}
