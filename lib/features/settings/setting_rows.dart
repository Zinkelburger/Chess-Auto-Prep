import 'package:flutter/foundation.dart';

import '../../chess/generation/expectimax_options.dart';
import '../../storage/settings.dart';
import '../../storage/settings_store.dart';
import 'app_updates.dart';
import '../../ui/app_keys.dart';
import '../../ui/move_notation.dart';
import '../../workspace/search_settings.dart';
import 'lichess_account.dart';
import 'update_rows.dart';

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

enum DiagnosticCopyState { idle, copying, copied, failed }

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

  /// Null while the thing cannot be done: the button is shown disabled.
  final VoidCallback? run;
}

/// A value shown, not changed: the version, a key.
final class ShownSetting extends SettingControl {
  const ShownSetting(this.text);

  final String text;
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
  required VoidCallback openLicences,
  String? version,
  VoidCallback? copyDiagnostics,
  DiagnosticCopyState diagnostics = DiagnosticCopyState.idle,
  AppUpdates? updates,
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
      SettingRow(
        'Piece notation',
        ChoiceSetting(
          options: const [(false, 'Letters (KQRBN)'), (true, 'Figurines')],
          value: s.figurines,
          onChanged: (on) => change((now) => now.copyWith(figurines: on)),
        ),
        // A live sample, so the choice is seen before the page is left.
        hint:
            '${s.figurines ? figurineSan(_sampleLine) : _sampleLine}'
            ' · files keep the letters',
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
        'Rate reviews myself',
        ToggleSetting(
          value: s.training.rateReviews,
          onChanged: (on) => change(
            (now) =>
                now.copyWith(training: now.training.copyWith(rateReviews: on)),
          ),
        ),
        hint: 'Off: graded from your mistakes. On: 1–4 after each line.',
      ),
    ]),
    SettingGroup('Tactics', [
      SettingRow(
        'Accept other winning moves',
        ToggleSetting(
          value: s.acceptAlternativeAnswers,
          onChanged: (on) =>
              change((now) => now.copyWith(acceptAlternativeAnswers: on)),
        ),
        hint: 'Checks alternative answers at depth 14',
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
    SettingGroup('Expectimax', _expectimaxRows(s, change)),
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
        hint: account.problem ?? accountHint(account.status),
        warn: account.problem != null,
      ),
      if (account.status case SignedOut() || Checking())
        SettingRow(
          'Personal access token',
          SecretSetting(load: () async => null, save: account.useToken),
          hint: 'instead of logging in; from lichess.org/account/oauth/token',
        ),
    ]),
    SettingGroup('App', [
      if (updates != null)
        ...updateRows(updates)
      else
        SettingRow('Version', ShownSetting(version ?? 'Unknown')),
      SettingRow(
        'Licences',
        ActionSetting('View', openLicences),
        hint: 'Stockfish, Hivemind, Maia, fonts and every package',
      ),
      if (copyDiagnostics != null)
        SettingRow(
          'Diagnostics',
          ActionSetting('Copy diagnostics', copyDiagnostics),
          hint: switch (diagnostics) {
            DiagnosticCopyState.idle =>
              'Version, platform and recent log for a bug report',
            DiagnosticCopyState.copying => 'Preparing diagnostics…',
            DiagnosticCopyState.copied => 'Diagnostics copied.',
            DiagnosticCopyState.failed =>
              'Could not copy diagnostics. Try again.',
          },
          warn: diagnostics == DiagnosticCopyState.failed,
        ),
      SettingRow(
        'Log folder',
        ActionSetting('Open', openLogFolder),
        hint: 'app.log, for a bug report',
      ),
    ]),
    SettingGroup('Shortcuts', [
      for (final key in AppKey.values)
        SettingRow(
          key.action,
          ShownSetting(key.allLabels),
          hint: key.place.label,
        ),
    ]),
  ];
}

const _sampleLine = '1.e4 e5 2.Nf3 Nc6 3.Bb5';

String accountHint(AccountStatus status) => switch (status) {
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

/// The Expectimax tab's settings, as its gear shows them. The opponent's
/// rating is the Repertoire row above: one number for both.
List<SettingRow> _expectimaxRows(
  Settings s,
  void Function(Settings Function(Settings now) edit) change,
) {
  final e = s.expectimax;
  void set(ExpectimaxOptions Function(ExpectimaxOptions now) edit) =>
      change((now) => now.copyWith(expectimax: edit(now.expectimax)));
  SettingRow number(
    (String, String) copy,
    int value,
    int min,
    int max,
    ExpectimaxOptions Function(ExpectimaxOptions now, int n) edit, {
    String? hint,
  }) => SettingRow(
    copy.$1,
    NumberSetting(
      value: value,
      min: min,
      max: max,
      onChanged: (n) => set((now) => edit(now, n)),
    ),
    hint: hint ?? copy.$2,
  );
  return [
    SettingRow(
      'Method',
      ChoiceSetting(
        options: [for (final m in SearchMethod.values) (m, m.label)],
        value: e.method,
        onChanged: (m) => set((now) => now.copyWith(method: m)),
      ),
    ),
    SettingRow(
      SearchSettingCopy.replies.$1,
      ChoiceSetting(
        options: SearchSettingCopy.replySources,
        value: e.replies,
        onChanged: (source) => set((now) => now.copyWith(replies: source)),
      ),
      hint: SearchSettingCopy.replies.$2,
    ),
    SettingRow(
      'Fall back to Maia',
      ToggleSetting(
        value: e.maiaFallback,
        onChanged: (on) => set((now) => now.copyWith(maiaFallback: on)),
      ),
      hint: 'where the database has too few games at a position',
    ),
    number(
      SearchSettingCopy.fallback,
      e.fallbackUnder,
      1,
      ExpectimaxOptions.maxFallbackUnder,
      (now, n) => now.copyWith(fallbackUnder: n),
    ),
    number(
      SearchSettingCopy.depth,
      e.depth ?? 0,
      0,
      ExpectimaxOptions.maxDepth,
      (now, n) => now.withDepth(n == 0 ? null : n),
      hint: '${SearchSettingCopy.depth.$2}; 0 is no limit',
    ),
    number(
      SearchSettingCopy.rootMoves,
      e.rootMoves,
      1,
      ExpectimaxOptions.maxMoves,
      (now, n) => now.copyWith(rootMoves: n),
    ),
    number(
      SearchSettingCopy.candidateMoves,
      e.candidateMoves,
      1,
      ExpectimaxOptions.maxMoves,
      (now, n) => now.copyWith(candidateMoves: n),
    ),
    number(
      SearchSettingCopy.rare,
      e.rareOnceIn,
      0,
      ExpectimaxOptions.maxRareOnceIn,
      // One game in one is every game: the step past zero is two.
      (now, n) =>
          now.copyWith(rareOnceIn: n == 1 ? (now.rareOnceIn == 0 ? 2 : 0) : n),
    ),
    number(
      SearchSettingCopy.evalDepth,
      e.evalDepth,
      ExpectimaxOptions.minEvalDepth,
      ExpectimaxOptions.maxEvalDepth,
      (now, n) => now.copyWith(evalDepth: n),
    ),
    SettingRow(
      SearchSettingCopy.source.$1,
      ChoiceSetting(
        options: SearchSettingCopy.sources,
        value: e.source,
        onChanged: (source) => set((now) => now.copyWith(source: source)),
      ),
      hint: SearchSettingCopy.source.$2,
    ),
  ];
}
