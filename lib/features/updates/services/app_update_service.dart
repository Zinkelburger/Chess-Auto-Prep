/// Checks GitHub for a newer release, downloads and verifies the asset for
/// this install, and hands it to [UpdateInstaller] to swap in after the app
/// closes. The widget layer only reads [phase], [release], [progress] and
/// [error] and calls the verbs.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../../services/storage/app_paths.dart';
import '../../../services/storage/file_mutation_service.dart';
import '../../../utils/safe_change_notifier.dart';
import 'update_installer.dart';
import 'update_release.dart';

enum UpdatePhase {
  idle,
  checking,
  available,
  downloading,
  ready,
  scheduled,
  failed,
}

/// Preference keys. `updates.downloadAutomatically` is also seeded by tests.
abstract final class _Prefs {
  static const checkAutomatically = 'updates.checkAutomatically';
  static const downloadAutomatically = 'updates.downloadAutomatically';
  static const lastAttempt = 'updates.lastAttempt';
  static const cachedPayload = 'updates.cachedPayload';
}

/// Written by the helper script when an install fails after the app closed.
const _lastErrorFileName = 'last-error.txt';

const _backgroundCheckInterval = Duration(hours: 1);
const _automaticCheckSpacing = Duration(hours: 24);
const _releaseCheckTimeout = Duration(seconds: 20);
const _downloadConnectTimeout = Duration(seconds: 30);
const _downloadStallTimeout = Duration(seconds: 45);
const _cancelPoll = Duration(milliseconds: 100);
const _cancelPolls = 40;

class AppUpdateService extends ChangeNotifier with SafeChangeNotifier {
  AppUpdateService({
    http.Client? client,
    UpdateInstaller? installer,
    Future<Directory> Function()? directory,
    Future<String> Function()? version,
  }) : _client = client ?? http.Client(),
       _installer = installer ?? UpdateInstaller(),
       _directory = directory ?? _updateDirectory,
       _version =
           version ?? (() async => (await PackageInfo.fromPlatform()).version);

  static final instance = AppUpdateService();

  final http.Client _client;
  final UpdateInstaller _installer;
  final Future<Directory> Function() _directory;
  final Future<String> Function() _version;
  Timer? _timer;
  Future<void>? _initializing;
  late final SharedPreferences _prefs;

  /// The verified asset on disk, once downloaded.
  File? _payload;

  /// The armed marker while an install is scheduled.
  File? _armed;

  bool _automaticChecks = true;
  bool _automaticDownload = true;
  String _currentVersion = '';
  InstallKind _kind = InstallKind.manual;
  UpdatePhase _phase = UpdatePhase.idle;
  UpdateRelease? _release;
  String? _error;
  String? _downloadDirectory;
  double _progress = 0;
  bool _hasChecked = false;
  String? _previousInstallError;

  bool get automaticChecks => _automaticChecks;
  bool get automaticDownload => _automaticDownload;
  String get currentVersion => _currentVersion;
  InstallKind get kind => _kind;
  UpdatePhase get phase => _phase;

  /// The newer release found by the last check, or null.
  UpdateRelease? get release => _release;

  /// What went wrong, while [phase] is [UpdatePhase.failed].
  String? get error => _error;

  /// Where the payload and helper logs live, once a download has started.
  String? get downloadDirectory => _downloadDirectory;

  /// Download progress, 0–1.
  double get progress => _progress;

  /// Whether a check has completed since start-up.
  bool get hasChecked => _hasChecked;

  /// The helper's report from a failed install on a previous run.
  String? get previousInstallError => _previousInstallError;

  bool get canCancelInstall => _armed != null;
  bool get busy =>
      phase == UpdatePhase.checking || phase == UpdatePhase.downloading;
  bool get canInstall => kind != InstallKind.manual;

  static Future<Directory> _updateDirectory() async =>
      Directory(p.join((await AppPaths.cacheDirectory()).path, 'updates'));

  Future<void> initialize() => _initializing ??= _initialize();

  Future<void> _initialize() async {
    _prefs = await SharedPreferences.getInstance();
    _automaticChecks = _prefs.getBool(_Prefs.checkAutomatically) ?? true;
    _automaticDownload = _prefs.getBool(_Prefs.downloadAutomatically) ?? true;
    _currentVersion = await _version();
    _kind = await _installer.detect();
    final previousError = File(
      p.join((await _directory()).path, _lastErrorFileName),
    );
    if (await previousError.exists()) {
      _previousInstallError = await previousError.readAsString();
    }
    notifyListeners();
  }

  /// Initializes and, in release builds on the desktop platforms that can
  /// self-update, checks now and then hourly in the background.
  Future<void> start() async {
    try {
      await initialize();
      if (isDisposed) return;
      // Development builds never contact GitHub in the background.
      if (kReleaseMode && (Platform.isLinux || Platform.isWindows)) {
        _timer ??= Timer.periodic(
          _backgroundCheckInterval,
          (_) => unawaited(check(automatic: true)),
        );
        await check(automatic: true);
      }
    } catch (e) {
      _fail(e);
    }
  }

  Future<void> setAutomaticChecks(bool value) async {
    await initialize();
    await _prefs.setBool(_Prefs.checkAutomatically, value);
    _automaticChecks = value;
    notifyListeners();
  }

  Future<void> setAutomaticDownload(bool value) async {
    await initialize();
    await _prefs.setBool(_Prefs.downloadAutomatically, value);
    _automaticDownload = value;
    notifyListeners();
  }

  /// Asks GitHub for the latest release. An [automatic] check is skipped when
  /// the user turned them off or one ran in the last day. A newer release is
  /// downloaded straight away when automatic download is on.
  Future<void> check({bool automatic = false}) async {
    if (!_canStartWork) return;
    try {
      await initialize();
      if (!_canStartWork) return;
      final now = DateTime.now();
      if (automatic && !_automaticCheckDue(now)) return;
      _phase = UpdatePhase.checking;
      _error = null;
      notifyListeners();
      await _prefs.setInt(_Prefs.lastAttempt, now.millisecondsSinceEpoch);
      _release = await _fetchLatestRelease();
      _payload = null;
      _hasChecked = true;
      _phase = _release == null ? UpdatePhase.idle : UpdatePhase.available;
      notifyListeners();
      if (_release != null && automaticDownload && canInstall && !isDisposed) {
        await download();
      }
    } catch (e) {
      _fail(e);
    }
  }

  /// Not already checking, downloading or armed, and still alive.
  bool get _canStartWork =>
      !busy && phase != UpdatePhase.scheduled && !isDisposed;

  bool _automaticCheckDue(DateTime now) {
    if (!automaticChecks) return false;
    final last = _prefs.getInt(_Prefs.lastAttempt) ?? 0;
    final age = now.millisecondsSinceEpoch - last;
    return age < 0 || age >= _automaticCheckSpacing.inMilliseconds;
  }

  /// The newest release that is newer than this build, or null when there
  /// is none (or the repository has no releases at all).
  Future<UpdateRelease?> _fetchLatestRelease() async {
    final response = await _client
        .get(
          Uri.https(
            'api.github.com',
            '/repos/$updateRepository/releases/latest',
          ),
          headers: {
            'Accept': 'application/vnd.github+json',
            'X-GitHub-Api-Version': '2022-11-28',
            'User-Agent': 'Chess-Auto-Prep/$currentVersion',
          },
        )
        .timeout(_releaseCheckTimeout);
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw HttpException(
        'GitHub update check returned ${response.statusCode}. Try again later.',
      );
    }
    return UpdateRelease.parse(
      jsonDecode(response.body) as Map<String, dynamic>,
      currentVersion,
      kind,
    );
  }

  /// Downloads the release asset into a fresh attempt directory and verifies
  /// its size and SHA-256 before it counts as ready. A payload verified on an
  /// earlier run is reused without another transfer.
  Future<void> download() async {
    final target = release;
    if (target == null || !canInstall || !_canStartWork) return;
    File? partial;
    try {
      _phase = UpdatePhase.downloading;
      _progress = 0;
      _error = null;
      notifyListeners();
      final root = await _directory();
      await root.create(recursive: true);
      final cached = await _cachedPayload(root, target);
      if (cached != null) {
        _becomeReady(cached);
        return;
      }
      // A private attempt directory avoids stale payloads, helper signals, or
      // two running app instances sharing a file being written.
      final dir = await root.createTemp('${target.tag}-');
      _downloadDirectory = dir.path;
      partial = File(p.join(dir.path, '${target.assetName}.part'));
      await _fetchPayload(target, partial);
      if (!await _matchesRelease(partial, target)) {
        throw const FormatException(
          'Update checksum verification failed. The download was discarded.',
        );
      }
      final verified = File(p.join(dir.path, target.assetName));
      await FileMutationService.instance.moveFileNoReplace(
        partial,
        verified,
        allowedRoot: dir,
      );
      partial = null;
      await _prefs.setString(_Prefs.cachedPayload, verified.path);
      _becomeReady(verified);
    } catch (e) {
      _fail(e);
    } finally {
      if (partial != null) {
        await FileMutationService.instance.deleteDisposableFile(
          partial,
          allowedRoot: partial.parent,
        );
      }
    }
  }

  /// The payload remembered from an earlier run, if it is still inside
  /// [root], is the asset of [target], and still verifies.
  Future<File?> _cachedPayload(Directory root, UpdateRelease target) async {
    final cachedPath = _prefs.getString(_Prefs.cachedPayload);
    if (cachedPath == null ||
        !p.isWithin(root.path, cachedPath) ||
        p.basename(cachedPath) != target.assetName) {
      return null;
    }
    final cached = File(cachedPath);
    if (!await cached.exists()) return null;
    return await _matchesRelease(cached, target) ? cached : null;
  }

  /// Streams the asset into [partial], refusing a transfer whose announced
  /// or actual size disagrees with the release.
  Future<void> _fetchPayload(UpdateRelease target, File partial) async {
    final response = await _client
        .send(http.Request('GET', target.url))
        .timeout(_downloadConnectTimeout);
    if (response.statusCode != 200) {
      throw HttpException('Update download returned ${response.statusCode}.');
    }
    if (response.contentLength != null &&
        response.contentLength != target.size) {
      throw const FormatException(
        'Update download size does not match the release.',
      );
    }
    var received = 0;
    var lastPercent = -1;
    final sink = partial.openWrite();
    try {
      await sink.addStream(
        response.stream.timeout(_downloadStallTimeout).map((bytes) {
          received += bytes.length;
          if (received > target.size) {
            throw const FormatException(
              'Update download exceeds the expected size.',
            );
          }
          _progress = received / target.size;
          final percent = (_progress * 100).floor();
          if (percent != lastPercent) {
            lastPercent = percent;
            notifyListeners();
          }
          return bytes;
        }),
      );
      await sink.flush();
    } finally {
      await sink.close();
    }
  }

  static Future<bool> _matchesRelease(File file, UpdateRelease target) async =>
      await file.length() == target.size &&
      (await sha256.bind(file.openRead()).first).toString() == target.sha256;

  void _becomeReady(File payload) {
    _payload = payload;
    _downloadDirectory = payload.parent.path;
    _phase = UpdatePhase.ready;
    notifyListeners();
  }

  /// Arms the installer with the verified payload. A second press while the
  /// helper is still acknowledging start-up does nothing.
  Future<void> scheduleInstall() async {
    final payload = _payload;
    final target = release;
    if (phase != UpdatePhase.ready || payload == null || target == null) {
      return;
    }
    _phase = UpdatePhase.scheduled;
    notifyListeners();
    try {
      _armed = await _installer.schedule(payload, target, kind);
      notifyListeners();
    } catch (e) {
      _fail(e);
    }
  }

  /// Disarms a scheduled install and waits for the helper to notice.
  Future<void> cancelInstall() async {
    final armed = _armed;
    if (armed == null) return;
    await FileMutationService.instance.deleteDisposableFile(
      armed,
      allowedRoot: armed.parent,
    );
    // Do not allow re-arming until the old helper has observed cancellation.
    final ready = File(
      p.join(armed.parent.path, UpdateInstaller.helperReadyFileName),
    );
    for (var i = 0; i < _cancelPolls && await ready.exists(); i++) {
      await Future<void>.delayed(_cancelPoll);
    }
    if (await ready.exists()) {
      _fail(
        StateError(
          'Installation cancelled, but the helper has not stopped yet. Check again later.',
        ),
      );
      return;
    }
    _armed = null;
    _phase = UpdatePhase.ready;
    notifyListeners();
  }

  void _fail(Object e) {
    _error = e.toString();
    _phase = UpdatePhase.failed;
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _client.close();
    super.dispose();
  }
}
