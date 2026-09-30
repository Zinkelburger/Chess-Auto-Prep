import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../diagnostics/log.dart';
import '../../net/github_releases.dart';
import '../../storage/settings_store.dart';
import '../../storage/update_choices.dart';
import '../../storage/update_files.dart';
import '../../storage/update_install.dart';
import 'update_offer.dart';

sealed class UpdateStatus {
  const UpdateStatus();
}

/// Nothing asked since the app started.
final class NotChecked extends UpdateStatus {
  const NotChecked();
}

final class CheckingForUpdate extends UpdateStatus {
  const CheckingForUpdate();
}

final class UpToDate extends UpdateStatus {
  const UpToDate();
}

/// A newer release, not downloaded.
final class UpdateOffered extends UpdateStatus {
  const UpdateOffered(this.offer);

  final UpdateOffer offer;
}

final class UpdateDownloading extends UpdateStatus {
  const UpdateDownloading(this.offer, this.fraction);

  final UpdateOffer offer;

  /// 0–1.
  final double fraction;
}

/// Downloaded and verified; nothing armed.
final class UpdateDownloaded extends UpdateStatus {
  const UpdateDownloaded(this.offer, this.payload);

  final UpdateOffer offer;
  final VerifiedPayload payload;
}

/// The helper is being started.
final class UpdateArming extends UpdateStatus {
  const UpdateArming(this.offer, this.payload);

  final UpdateOffer offer;
  final VerifiedPayload payload;
}

/// The helper waits for the app to close, then installs.
final class UpdateArmed extends UpdateStatus {
  const UpdateArmed(this.offer, this.payload, this.armed);

  final UpdateOffer offer;
  final VerifiedPayload payload;
  final String armed;
}

/// Installation was cancelled, but the helper has not stopped yet. Its
/// folder is not armed again until it has; Try again asks it again.
final class UpdateHelperStillRunning extends UpdateStatus {
  const UpdateHelperStillRunning(this.offer, this.payload, this.armed);

  final UpdateOffer offer;
  final VerifiedPayload payload;
  final String armed;
}

enum UpdateProblem {
  unreachable,
  rateLimited,
  github,
  incompleteRelease,
  sizeMismatch,
  tooLarge,
  checksum,
  transfer,
  helperNotStarted,

  /// Another helper still holds the install lock.
  helperBusy,
}

final class UpdateFailed extends UpdateStatus {
  const UpdateFailed(this.problem, {this.offer});

  final UpdateProblem problem;

  /// The release it failed on, when it got that far; Try again goes on
  /// from there.
  final UpdateOffer? offer;
}

/// How the app reaches outside itself for updates.
typedef UpdateOutside = ({
  AppReleases releases,
  UpdateFolder folder,
  UpdateInstaller installer,
  Future<String> Function() version,

  /// Whether this build checks by itself: release builds do, development
  /// builds only when pointed at a fixture.
  bool automatic,
  Future<bool> Function(Uri page) openPage,
  void Function(String folder) showFolder,
});

/// The app's updates: checks GitHub at start-up and then at most once a
/// day, downloads and verifies the file for this install, and arms the
/// helper that installs it after the app closes.
///
/// One job at a time: a check, a download or an install already under way
/// turns a second request away. Every answer is checked against a disposed
/// owner before it is published. A check the app made by itself that fails
/// is only logged — the network being away is not news — while one the
/// user asked for says why.
final class AppUpdates extends ChangeNotifier {
  AppUpdates(
    this._outside, {
    required SettingsStore settings,
    DateTime Function() now = DateTime.now,
    this.startDelay = const Duration(seconds: 10),
    this.poll = const Duration(hours: 1),
  }) : _settings = settings,
       _now = now;

  final UpdateOutside _outside;
  final SettingsStore _settings;
  final DateTime Function() _now;

  /// How long after start-up the first check waits, so it never competes
  /// with opening the app.
  final Duration startDelay;

  /// How often the app looks whether a day has passed since the last check.
  final Duration poll;

  static const checkSpacing = Duration(hours: 24);

  UpdateStatus _status = const NotChecked();
  InstallKind _kind = InstallKind.manual;
  String _version = '';
  FailedInstall? _previousFailure;
  UpdateOffer? _prompt;
  final _prompted = <String>{};
  bool _installWhenReady = false;
  Completer<void>? _stop;
  Timer? _timer;
  bool _disposed = false;

  UpdateStatus get status => _status;
  InstallKind get kind => _kind;

  /// This copy's version, once read.
  String get version => _version;

  /// What the helper said when the last install failed, at the one start
  /// after it.
  String? get previousFailure => _previousFailure?.report;

  /// A release found by a check the app made by itself, not yet answered
  /// Later or Skip. Each version is offered once per run.
  UpdateOffer? get prompt => _prompt;
  UpdateChoices get choices => _settings.value.updates;
  bool get installWhenReady => _installWhenReady;

  bool get _busy => switch (_status) {
    CheckingForUpdate() ||
    UpdateDownloading() ||
    UpdateArming() ||
    UpdateArmed() ||
    UpdateHelperStillRunning() => true,
    _ => false,
  };

  /// Reads the version and the kind of install, collects a failed install's
  /// report, then starts the daily checks when this build makes them.
  Future<void> start() async {
    try {
      _version = await _outside.version();
    } on Object catch (error) {
      log.w('read the app version', error);
    }
    final kind = await _outside.installer.detect();
    final failure = await _outside.folder.takeFailedInstall();
    if (_disposed) return;
    _kind = kind;
    _previousFailure = failure;
    notifyListeners();
    if (!_outside.automatic) return;
    _timer = Timer(startDelay, () {
      _checkIfDue();
      _timer = Timer.periodic(poll, (_) => _checkIfDue());
    });
  }

  void _checkIfDue() {
    if (!choices.checkAutomatically) return;
    final last = choices.lastChecked;
    final now = _now();
    if (last != null &&
        !last.isAfter(now) &&
        now.difference(last) < checkSpacing) {
      return;
    }
    unawaited(check(automatic: true));
  }

  /// Asks GitHub for the newest release. An [automatic] check that finds
  /// a new version offers it once and, when the user lets it, downloads it.
  Future<void> check({bool automatic = false}) async {
    if (_disposed || _busy) return;
    final before = _status;
    _set(const CheckingForUpdate());
    final answer = await _outside.releases.latest();
    if (_disposed) return;
    unawaited(_remember(choices.copyWith(lastChecked: _now())));
    final UpdateStatus next = switch (answer) {
      NoRelease() => const UpToDate(),
      ReleaseCheckFailed(:final problem) => UpdateFailed(switch (problem) {
        ReleaseProblem.unreachable => UpdateProblem.unreachable,
        ReleaseProblem.rateLimited => UpdateProblem.rateLimited,
        ReleaseProblem.http || ReleaseProblem.malformed => UpdateProblem.github,
      }),
      LatestRelease(:final release) => switch (offerFor(
        release,
        current: _version,
        kind: _kind,
      )) {
        Newer(:final offer) => switch (before) {
          UpdateDownloaded(offer: final had) when had == offer => before,
          _ => UpdateOffered(offer),
        },
        NotNewer() => const UpToDate(),
        Incomplete() => const UpdateFailed(UpdateProblem.incompleteRelease),
      },
    };
    if (automatic && next is UpdateFailed) {
      _set(before);
      return;
    }
    _set(next);
    if (next case UpdateOffered(:final offer) when automatic) {
      _offerOnce(offer);
      if (choices.downloadAutomatically && offer.tag != choices.skipped) {
        await download();
      }
    }
  }

  void _offerOnce(UpdateOffer offer) {
    if (offer.tag == choices.skipped || !_prompted.add(offer.tag)) return;
    _prompt = offer;
    notifyListeners();
  }

  /// Downloads the release's file for this install and verifies its size
  /// and SHA-256; a file an earlier run verified is used without a transfer.
  Future<void> download() async {
    final offer = _offerIn(_status);
    final asset = offer?.asset;
    if (_disposed || _busy || offer == null || asset == null) return;
    final stop = _stop = Completer<void>();
    _set(UpdateDownloading(offer, 0));
    final kept = await _outside.folder.verified(asset.payload);
    if (_disposed) return;
    if (stop.isCompleted) return _cancelled(offer);
    if (kept != null) return _downloaded(offer, kept);
    final started = await _outside.releases.download(asset.url);
    if (_disposed || stop.isCompleted) {
      if (started case AssetStream(:final bytes)) {
        unawaited(bytes.listen(null).cancel());
      }
      return _cancelled(offer);
    }
    switch (started) {
      case AssetRefused():
        return _fail(UpdateProblem.transfer, offer);
      case AssetStream(:final bytes, :final length):
        final received = await _outside.folder.receive(
          asset.payload,
          bytes,
          announced: length,
          progress: (n) => _progressed(offer, n / asset.payload.size),
          stop: stop.future,
        );
        if (_disposed) return;
        switch (received) {
          case Verified(:final payload):
            // Before arming: asking whether a helper runs briefly takes
            // the lock a starting helper needs.
            await _prune(payload);
            if (_disposed) return;
            if (stop.isCompleted) return _cancelled(offer);
            return _downloaded(offer, payload);
          case Refused(:final refusal):
            return _fail(switch (refusal) {
              Refusal.sizeMismatch => UpdateProblem.sizeMismatch,
              Refusal.tooLarge => UpdateProblem.tooLarge,
              Refusal.checksum => UpdateProblem.checksum,
            }, offer);
          case ReceiveCancelled():
            return _cancelled(offer);
          case ReceiveFailed():
            return _fail(UpdateProblem.transfer, offer);
        }
    }
  }

  /// Redraws only when the whole percentage changes.
  void _progressed(UpdateOffer offer, double fraction) {
    if (_disposed || _status is! UpdateDownloading) return;
    final shown = (_status as UpdateDownloading).fraction;
    _status = UpdateDownloading(offer, fraction);
    if ((fraction * 100).floor() != (shown * 100).floor()) notifyListeners();
  }

  /// Cancel was pressed: back to the offer, and an Install pressed before
  /// it is cancelled too.
  void _cancelled(UpdateOffer offer) {
    _installWhenReady = false;
    _set(UpdateOffered(offer));
  }

  void cancelDownload() {
    if (_status is! UpdateDownloading) return;
    if (_stop case final stop? when !stop.isCompleted) stop.complete();
  }

  /// Removes older downloads nothing uses any more.
  Future<void> _prune(VerifiedPayload keep) async {
    final folder = _outside.folder;
    try {
      final running = await _outside.installer.helperRunning(folder.root.path);
      await folder.prune(keep: keep, helperRunning: running);
    } on Object catch (error) {
      log.w('remove old update downloads', error);
    }
  }

  /// Goes on to arm the helper when Install was pressed meanwhile.
  Future<void> _downloaded(UpdateOffer offer, VerifiedPayload payload) async {
    _set(UpdateDownloaded(offer, payload));
    if (_installWhenReady) await install();
  }

  /// Installs when the app closes: arms the helper now when the file is
  /// here, else downloads it first and arms it once it is verified.
  Future<void> install() async {
    if (_disposed || _kind == InstallKind.manual) return;
    switch (_status) {
      case UpdateDownloaded(:final offer, :final payload):
        _installWhenReady = false;
        _set(UpdateArming(offer, payload));
        final started = await _outside.installer.schedule(payload, _kind);
        if (_disposed) return;
        _set(switch (started) {
          HelperArmed(:final armed) => UpdateArmed(offer, payload, armed),
          HelperNotStarted() => UpdateFailed(
            UpdateProblem.helperNotStarted,
            offer: offer,
          ),
          HelperBusy() => UpdateFailed(UpdateProblem.helperBusy, offer: offer),
        });
      case UpdateDownloading():
        _installWhenReady = true;
        notifyListeners();
      case UpdateOffered() || UpdateFailed(offer: UpdateOffer()):
        _installWhenReady = true;
        await download();
      case NotChecked() ||
          CheckingForUpdate() ||
          UpToDate() ||
          UpdateArming() ||
          UpdateArmed() ||
          UpdateHelperStillRunning() ||
          UpdateFailed():
        return;
    }
  }

  /// Disarms the helper, or asks again one that has not stopped yet; the
  /// download stays for a later install.
  Future<void> cancelInstall() async {
    if (_status
        case UpdateArmed(:final offer, :final payload, :final armed) ||
            UpdateHelperStillRunning(
              :final offer,
              :final payload,
              :final armed,
            )) {
      final stopped = await _outside.installer.cancel(armed);
      if (_disposed) return;
      _set(
        stopped
            ? UpdateDownloaded(offer, payload)
            : UpdateHelperStillRunning(offer, payload, armed),
      );
    }
  }

  /// Answers the prompt: not now.
  void later() {
    _prompt = null;
    notifyListeners();
  }

  /// Answers the prompt: never offer [offer]'s version again.
  void skip(UpdateOffer offer) {
    _prompt = null;
    notifyListeners();
    unawaited(_remember(choices.copyWith(skipped: offer.tag)));
  }

  /// Answers the prompt: install [offer] (or, when this copy updates by
  /// hand, open its release page).
  Future<void> accept(UpdateOffer offer) async {
    _prompt = null;
    notifyListeners();
    if (offer.installable) return install();
    await openPage(offer);
  }

  /// Opens [offer]'s release on GitHub: its notes, and the download for a
  /// copy that updates by hand.
  Future<void> openPage(UpdateOffer offer) async {
    await _outside.openPage(offer.page);
  }

  /// Shows the folder holding the failed install's `install.log`.
  void showInstallLog() => _outside.showFolder(
    _previousFailure?.folder ?? _outside.folder.root.path,
  );

  Future<void> setCheckAutomatically(bool on) =>
      _remember(choices.copyWith(checkAutomatically: on));

  Future<void> setDownloadAutomatically(bool on) =>
      _remember(choices.copyWith(downloadAutomatically: on));

  /// Takes [next], made from [choices] as they are now, into the settings
  /// as they are now: [SettingsStore.update] installs the value at once, so
  /// a change to another field is never undone.
  Future<void> _remember(UpdateChoices next) =>
      _settings.update(_settings.value.copyWith(updates: next));

  UpdateOffer? _offerIn(UpdateStatus status) => switch (status) {
    UpdateOffered(:final offer) ||
    UpdateDownloading(:final offer) ||
    UpdateDownloaded(:final offer) ||
    UpdateArming(:final offer) ||
    UpdateArmed(:final offer) ||
    UpdateHelperStillRunning(:final offer) => offer,
    UpdateFailed(:final offer) => offer,
    NotChecked() || CheckingForUpdate() || UpToDate() => null,
  };

  void _fail(UpdateProblem problem, UpdateOffer offer) {
    _installWhenReady = false;
    _set(UpdateFailed(problem, offer: offer));
  }

  void _set(UpdateStatus next) {
    if (_disposed) return;
    _status = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    if (_stop case final stop? when !stop.isCompleted) stop.complete();
    super.dispose();
  }
}
