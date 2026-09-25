import 'package:flutter/foundation.dart';

import '../../storage/settings.dart';
import '../../storage/settings_store.dart';
import 'lichess_account.dart';

/// One row of the settings page: what it is called, one line more when the
/// name cannot carry it, and the one control that changes it.
final class SettingRow {
  const SettingRow(this.label, this.control, {this.hint, this.warn = false});

  final String label;
  final String? hint;

  /// The hint is a problem, and is drawn as one.
  final bool warn;
  final SettingControl control;

  /// Whether [query] finds this row.
  bool matches(String query) =>
      label.toLowerCase().contains(query) ||
      (hint ?? '').toLowerCase().contains(query);
}

/// A place in the list on the left, and the rows it shows.
final class SettingGroup {
  const SettingGroup(this.name, this.rows);

  final String name;
  final List<SettingRow> rows;
}

sealed class SettingControl {
  const SettingControl();
}

/// Two or three fixed choices, shown side by side.
final class ChoiceSetting<T extends Object> extends SettingControl {
  const ChoiceSetting({
    required this.options,
    required this.value,
    required this.onChanged,
  });

  final List<(T, String)> options;
  final T value;
  final ValueChanged<T> onChanged;

  /// Takes [chosen], one of [options]' values, from a widget that holds the
  /// setting without its type: the row list is one list of controls.
  void pick(Object chosen) => onChanged(chosen as T);
}

/// A whole number, typed or stepped.
final class NumberSetting extends SettingControl {
  const NumberSetting({
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.step = 1,
    this.unit,
  });

  final int value;
  final int min;
  final int max;
  final int step;

  /// Shown after the number: `MB`.
  final String? unit;
  final ValueChanged<int> onChanged;
}

final class ToggleSetting extends SettingControl {
  const ToggleSetting({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;
}

/// A value that is kept elsewhere and never shown in full: a token. It is
/// read when the row appears and written when the user leaves the field.
final class SecretSetting extends SettingControl {
  const SecretSetting({required this.load, required this.save});

  final Future<String?> Function() load;

  /// Whether the value was kept.
  final Future<bool> Function(String value) save;
}

/// A button, for the few things on the page that are done rather than set.
final class ActionSetting extends SettingControl {
  const ActionSetting(this.label, this.run);

  final String label;
  final VoidCallback run;
}

/// The Lichess account: log in, the wait for the browser, log out. The
/// row's hint says where it stands; the control is the one button it
/// needs now.
final class AccountSetting extends SettingControl {
  const AccountSetting(this.account);

  final LichessAccountState account;
}

/// The page's rows, from the settings as they are now. Built again on every
/// change, so a row always shows the value the store holds.
///
/// A row changes the settings as the store holds them when the change
/// lands, not as they were when the rows were built: two changes can land
/// before the next build — a typed number taken as the field loses focus
/// to a click on another row — and the second must not undo the first.
List<SettingGroup> settingGroups({
  required SettingsStore store,
  required int coresAvailable,
  required LichessAccountState account,
  required VoidCallback openLogFolder,
}) {
  final s = store.value;
  void change(Settings Function(Settings now) edit) =>
      store.update(edit(store.value));
  return [
    SettingGroup('Look', [
      SettingRow(
        'Board coordinates',
        ChoiceSetting(
          options: const [(true, 'Show'), (false, 'Hide')],
          value: s.boardCoordinates,
          onChanged: (on) =>
              change((now) => now.copyWith(boardCoordinates: on)),
        ),
      ),
    ]),
    SettingGroup('Training', [
      for (final (label, value, update) in [
        (
          'New lines per sitting',
          s.training.learnLimit,
          (int n, Settings now) => now.training.copyWith(learnLimit: n),
        ),
        (
          'Reviews per sitting',
          s.training.reviewLimit,
          (int n, Settings now) => now.training.copyWith(reviewLimit: n),
        ),
        (
          'Drill lines per sitting',
          s.training.drillLimit,
          (int n, Settings now) => now.training.copyWith(drillLimit: n),
        ),
      ])
        SettingRow(
          label,
          NumberSetting(
            value: value,
            min: 0,
            max: 1000,
            onChanged: (n) =>
                change((now) => now.copyWith(training: update(n, now))),
          ),
          hint: '0 = all lines. Applies to the next sitting.',
        ),
      SettingRow(
        'Move delay',
        NumberSetting(
          value: s.training.replyMillis,
          min: 200,
          max: 2000,
          step: 100,
          unit: 'ms',
          onChanged: (n) => change(
            (now) =>
                now.copyWith(training: now.training.copyWith(replyMillis: n)),
          ),
        ),
        hint: 'Time to see your move before the reply. Applies next sitting.',
      ),
      SettingRow(
        'Replay missed moves',
        ToggleSetting(
          value: s.training.replayMistakes,
          onChanged: (on) => change(
            (now) => now.copyWith(
              training: now.training.copyWith(replayMistakes: on),
            ),
          ),
        ),
      ),
      SettingRow(
        'Shuffle drills',
        ToggleSetting(
          value: s.training.shuffleDrill,
          onChanged: (on) => change(
            (now) =>
                now.copyWith(training: now.training.copyWith(shuffleDrill: on)),
          ),
        ),
        hint: 'Otherwise Drill follows the selected line order.',
      ),
    ]),
    SettingGroup('Engine', [
      SettingRow(
        'CPU cores',
        NumberSetting(
          value: s.engineCores,
          min: 1,
          max: coresAvailable,
          onChanged: (n) => change((now) => now.copyWith(engineCores: n)),
        ),
        hint: 'of $coresAvailable on this computer',
      ),
      SettingRow(
        'Memory',
        NumberSetting(
          value: s.engineMemoryMb,
          min: 16,
          max: Settings.maxMemoryMb,
          step: 64,
          unit: 'MB',
          onChanged: (n) => change((now) => now.copyWith(engineMemoryMb: n)),
        ),
      ),
      SettingRow(
        'Lines shown',
        NumberSetting(
          value: s.engineLines,
          min: 1,
          max: Settings.maxLines,
          onChanged: (n) => change((now) => now.copyWith(engineLines: n)),
        ),
      ),
    ]),
    SettingGroup('Repertoire', [
      SettingRow(
        'Opponent rating',
        NumberSetting(
          value: s.opponentElo,
          min: Settings.minElo,
          max: Settings.maxElo,
          step: 100,
          onChanged: (n) => change((now) => now.copyWith(opponentElo: n)),
        ),
        hint: 'their replies are predicted for this Elo',
      ),
      SettingRow(
        'Cover replies met once in',
        NumberSetting(
          value: s.coverOnceIn,
          min: Settings.minCoverOnceIn,
          max: Settings.maxCoverOnceIn,
          step: 5,
          unit: 'games',
          onChanged: (n) => change((now) => now.copyWith(coverOnceIn: n)),
        ),
        hint: 'rarer replies are not counted as gaps',
      ),
    ]),
    SettingGroup('Files', [
      SettingRow(
        'Copy files from outside Documents when opened',
        ToggleSetting(
          value: s.copyFilesIntoDocuments,
          onChanged: (on) =>
              change((now) => now.copyWith(copyFilesIntoDocuments: on)),
        ),
        hint: 'into Documents/pgn_collections, so they can be edited',
      ),
    ]),
    SettingGroup('Accounts', [
      SettingRow(
        'Lichess',
        AccountSetting(account),
        hint: account.problem ?? _accountHint(account.status),
        warn: account.problem != null,
      ),
      if (!account.canRetryRead)
        if (account.status case SignedOut() || Checking())
          SettingRow(
            'Personal access token',
            SecretSetting(load: () async => null, save: account.useToken),
            hint: 'instead of logging in; from lichess.org/account/oauth/token',
          ),
    ]),
    SettingGroup('App', [
      SettingRow(
        'Log folder',
        ActionSetting('Open', openLogFolder),
        hint: 'app.log, for a bug report',
      ),
    ]),
  ];
}

String _accountHint(AccountStatus status) => switch (status) {
  SignedOut() =>
    'lifts the API limits; needed for private studies and the explorer',
  Connecting(browserOpened: true) => 'Waiting for the browser…',
  Connecting() => 'The browser did not open. Copy the link and open it.',
  Checking() => 'Checking the token…',
  SigningOut() => 'Logging out…',
  SignedIn(:final account) =>
    'Logged in as ${account.username ?? 'an unnamed account'} · '
        '${account.personal ? 'personal access token' : 'until ${_day(account.until)}'}',
};

String _day(DateTime? when) => when == null
    ? 'revoked'
    : when.toLocal().toIso8601String().substring(0, 10);
