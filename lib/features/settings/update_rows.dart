import '../../storage/update_install.dart';
import '../../ui/relative_time.dart';
import 'app_updates.dart';
import 'setting_rows.dart';
import 'update_offer.dart';

/// The App page's update rows: the version with Check now, the two
/// switches, and a row for the update itself only while there is one.
List<SettingRow> updateRows(AppUpdates updates, {DateTime? now}) {
  final choices = updates.choices;
  final manual = updates.kind == InstallKind.manual;
  return [
    SettingRow(
      'Version',
      ActionSetting('Check now', () => updates.check()),
      hint: _versionHint(updates, now),
    ),
    SettingRow(
      'Check for updates automatically',
      ToggleSetting(
        value: choices.checkAutomatically,
        onChanged: updates.setCheckAutomatically,
      ),
      hint: 'At startup and once a day',
    ),
    if (!manual)
      SettingRow(
        'Download updates automatically',
        ToggleSetting(
          value: choices.downloadAutomatically,
          onChanged: updates.setDownloadAutomatically,
        ),
      ),
    ?_updateRow(updates),
    if (updates.previousFailure case final failure?)
      SettingRow(
        'Previous update did not finish',
        ActionSetting('Show log', updates.showInstallLog),
        hint: failure,
        warn: true,
      ),
  ];
}

String _versionHint(AppUpdates updates, DateTime? now) {
  final installed = updates.version.isEmpty
      ? 'Version unknown'
      : updates.version;
  final checked = updates.choices.lastChecked;
  final when = checked == null
      ? 'not checked yet'
      : 'checked ${relativeTime(checked, now: now)}';
  return switch (updates.status) {
    CheckingForUpdate() => '$installed · checking…',
    UpToDate() => '$installed · up to date · $when',
    _ => '$installed · $when',
  };
}

/// The update itself, while there is one: what it is, where it stands and
/// the one thing to do next.
SettingRow? _updateRow(AppUpdates updates) {
  const closing = 'installs when you close the app';
  String name(UpdateOffer offer) => 'Chess Auto Prep ${offer.version}';
  return switch (updates.status) {
    UpdateOffered(:final offer) when !offer.installable => SettingRow(
      name(offer),
      ActionSetting('Open releases', () => updates.openPage(offer)),
      hint: 'Available on GitHub',
    ),
    UpdateOffered(:final offer) => SettingRow(
      name(offer),
      ActionSetting('Install', () => updates.install()),
      hint: 'Available · $closing',
    ),
    UpdateDownloading(:final offer, :final fraction) => SettingRow(
      name(offer),
      ActionSetting('Cancel', updates.cancelDownload),
      hint:
          'Downloading… ${(fraction * 100).floor()}%'
          '${updates.installWhenReady ? ' · $closing' : ''}',
    ),
    UpdateDownloaded(:final offer) => SettingRow(
      name(offer),
      ActionSetting('Install', () => updates.install()),
      hint: 'Downloaded and verified',
    ),
    UpdateArming(:final offer) => SettingRow(
      name(offer),
      const ActionSetting('Cancel installation', null),
      hint: 'Starting the installer…',
    ),
    UpdateArmed(:final offer) => SettingRow(
      name(offer),
      ActionSetting('Cancel installation', () => updates.cancelInstall()),
      hint:
          'Installs when you close the app. '
          'Linux packages may ask for your password.',
    ),
    UpdateHelperStillRunning(:final offer) => SettingRow(
      name(offer),
      ActionSetting('Try again', () => updates.cancelInstall()),
      hint: 'Installation cancelled, but the installer has not stopped yet.',
      warn: true,
    ),
    UpdateFailed(:final problem, :final offer) => SettingRow(
      offer == null ? 'Update' : name(offer),
      ActionSetting(
        'Try again',
        offer != null && offer.installable
            ? () => updates.install()
            : () => updates.check(),
      ),
      hint: problemText(problem),
      warn: true,
    ),
    NotChecked() || CheckingForUpdate() || UpToDate() => null,
  };
}

/// Why an update did not go through, in one line.
String problemText(UpdateProblem problem) => switch (problem) {
  UpdateProblem.unreachable => 'Could not reach GitHub.',
  UpdateProblem.rateLimited => 'GitHub is busy. Try again later.',
  UpdateProblem.github => 'GitHub gave an unexpected answer. Try again later.',
  UpdateProblem.incompleteRelease =>
    'The release is not fully uploaded yet. Try again later.',
  UpdateProblem.sizeMismatch =>
    'The download was the wrong size and was discarded.',
  UpdateProblem.tooLarge =>
    'The download was larger than the release and was discarded.',
  UpdateProblem.checksum =>
    'The download failed verification and was discarded.',
  UpdateProblem.transfer => 'The download did not complete.',
  UpdateProblem.helperNotStarted => 'The installer did not start.',
  UpdateProblem.helperBusy => 'An earlier installer is still running.',
};
