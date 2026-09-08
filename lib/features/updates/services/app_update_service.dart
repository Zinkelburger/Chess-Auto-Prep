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
  SharedPreferences? _prefs;
  File? _payload;
  File? _armed;
  bool automaticChecks = true;
  bool automaticDownload = true;
  String currentVersion = '';
  InstallKind kind = InstallKind.manual;
  UpdatePhase phase = UpdatePhase.idle;
  UpdateRelease? release;
  String? error;
  String? downloadDirectory;
  double progress = 0;
  bool hasChecked = false;
  String? previousInstallError;
  bool get canCancelInstall => _armed != null;
  bool get busy =>
      phase == UpdatePhase.checking || phase == UpdatePhase.downloading;
  bool get canInstall => kind != InstallKind.manual;

  static Future<Directory> _updateDirectory() async =>
      Directory(p.join((await AppPaths.cacheDirectory()).path, 'updates'));

  Future<void> initialize() => _initializing ??= _initialize();
  Future<void> _initialize() async {
    _prefs = await SharedPreferences.getInstance();
    automaticChecks = _prefs!.getBool('updates.checkAutomatically') ?? true;
    automaticDownload =
        _prefs!.getBool('updates.downloadAutomatically') ?? true;
    currentVersion = await _version();
    kind = await _installer.detect();
    final previousError = File(
      p.join((await _directory()).path, 'last-error.txt'),
    );
    if (await previousError.exists()) {
      previousInstallError = await previousError.readAsString();
    }
    notifyListeners();
  }

  Future<void> start() async {
    try {
      await initialize();
      if (isDisposed) return;
      // Development builds never contact GitHub in the background.
      if (kReleaseMode && (Platform.isLinux || Platform.isWindows)) {
        _timer ??= Timer.periodic(
          const Duration(hours: 1),
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
    await _prefs!.setBool('updates.checkAutomatically', value);
    automaticChecks = value;
    notifyListeners();
  }

  Future<void> setAutomaticDownload(bool value) async {
    await initialize();
    await _prefs!.setBool('updates.downloadAutomatically', value);
    automaticDownload = value;
    notifyListeners();
  }

  Future<void> check({bool automatic = false}) async {
    if (busy || phase == UpdatePhase.scheduled || isDisposed) return;
    try {
      await initialize();
      if (busy || phase == UpdatePhase.scheduled || isDisposed) return;
      final now = DateTime.now();
      if (automatic) {
        if (!automaticChecks) return;
        final last = _prefs!.getInt('updates.lastAttempt') ?? 0;
        final age = now.millisecondsSinceEpoch - last;
        if (age >= 0 && age < const Duration(hours: 24).inMilliseconds) return;
      }
      phase = UpdatePhase.checking;
      error = null;
      notifyListeners();
      await _prefs!.setInt('updates.lastAttempt', now.millisecondsSinceEpoch);
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
          .timeout(const Duration(seconds: 20));
      if (response.statusCode == 404) {
        release = null;
      } else {
        if (response.statusCode != 200) {
          throw HttpException(
            'GitHub update check returned ${response.statusCode}. Try again later.',
          );
        }
        release = UpdateRelease.parse(
          jsonDecode(response.body) as Map<String, dynamic>,
          currentVersion,
          kind,
        );
      }
      _payload = null;
      hasChecked = true;
      phase = release == null ? UpdatePhase.idle : UpdatePhase.available;
      notifyListeners();
      if (release != null && automaticDownload && canInstall && !isDisposed) {
        await download();
      }
    } catch (e) {
      _fail(e);
    }
  }

  Future<void> download() async {
    final target = release;
    if (target == null ||
        !canInstall ||
        busy ||
        phase == UpdatePhase.scheduled ||
        isDisposed) {
      return;
    }
    File? partial;
    IOSink? sink;
    try {
      phase = UpdatePhase.downloading;
      progress = 0;
      error = null;
      notifyListeners();
      final root = await _directory();
      await root.create(recursive: true);
      final cachedPath = _prefs?.getString('updates.cachedPayload');
      if (cachedPath != null &&
          p.isWithin(root.path, cachedPath) &&
          p.basename(cachedPath) == target.assetName) {
        final cached = File(cachedPath);
        if (await cached.exists() &&
            await cached.length() == target.size &&
            (await sha256.bind(cached.openRead()).first).toString() ==
                target.sha256) {
          _payload = cached;
          downloadDirectory = cached.parent.path;
          phase = UpdatePhase.ready;
          notifyListeners();
          return;
        }
      }
      // A private attempt directory avoids stale payloads, helper signals, or
      // two running app instances sharing a file being written.
      final dir = await root.createTemp('${target.tag}-');
      downloadDirectory = dir.path;
      partial = File(p.join(dir.path, '${target.assetName}.part'));
      final response = await _client
          .send(http.Request('GET', target.url))
          .timeout(const Duration(seconds: 30));
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
      sink = partial.openWrite();
      await sink.addStream(
        response.stream.timeout(const Duration(seconds: 45)).map((bytes) {
          received += bytes.length;
          if (received > target.size) {
            throw const FormatException(
              'Update download exceeds the expected size.',
            );
          }
          progress = received / target.size;
          final percent = (progress * 100).floor();
          if (percent != lastPercent) {
            lastPercent = percent;
            notifyListeners();
          }
          return bytes;
        }),
      );
      await sink.flush();
      await sink.close();
      sink = null;
      if (received != target.size ||
          (await sha256.bind(partial.openRead()).first).toString() !=
              target.sha256) {
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
      _payload = verified;
      await _prefs?.setString('updates.cachedPayload', verified.path);
      partial = null;
      phase = UpdatePhase.ready;
      notifyListeners();
    } catch (e) {
      _fail(e);
    } finally {
      await sink?.close();
      if (partial != null) {
        await FileMutationService.instance.deleteDisposableFile(
          partial,
          allowedRoot: partial.parent,
        );
      }
    }
  }

  Future<void> scheduleInstall() async {
    if (phase != UpdatePhase.ready || _payload == null || release == null) {
      return;
    }
    // Block duplicate button presses while the helper acknowledges startup.
    phase = UpdatePhase.scheduled;
    notifyListeners();
    try {
      _armed = await _installer.schedule(_payload!, release!, kind);
      notifyListeners();
    } catch (e) {
      _fail(e);
    }
  }

  Future<void> cancelInstall() async {
    final armed = _armed;
    if (armed == null) return;
    await FileMutationService.instance.deleteDisposableFile(
      armed,
      allowedRoot: armed.parent,
    );
    // Do not allow re-arming until the old helper has observed cancellation.
    final ready = File(p.join(armed.parent.path, 'helper-ready'));
    for (var i = 0; i < 40 && await ready.exists(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
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
    phase = UpdatePhase.ready;
    notifyListeners();
  }

  void _fail(Object e) {
    error = e.toString();
    phase = UpdatePhase.failed;
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _client.close();
    super.dispose();
  }
}
