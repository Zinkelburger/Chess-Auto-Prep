import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../chess/generation/evaluation_source.dart';
import '../chess/generation/expectimax_options.dart';
import '../storage/settings.dart';
import '../storage/settings_store.dart';
import '../ui/theme.dart';

/// What each Expectimax setting is called and the one line under it, said
/// the same way behind the tab's gear and in Settings ▸ Expectimax.
abstract final class SearchSettingCopy {
  static const depth = ('Depth', 'half-moves searched from the board');
  static const rating = ('Maia rating', 'opponent replies at this Elo');
  static const rootMoves = ('First move', 'our best engine moves searched');
  static const candidateMoves = (
    'Later moves',
    'our best engine moves searched',
  );
  static const rare = (
    'Search replies met once in',
    'games; 0 searches every reply',
  );
  static const evalDepth = ('Engine depth', 'each position scored this deep');
  static const source = (
    'Evaluation',
    'a database answers first, the engine the rest',
  );

  /// The evaluation sources by the name of what answers first.
  static const sources = [
    (EvaluationSource.stockfish, 'Engine'),
    (EvaluationSource.chessDb, 'ChessDB'),
    (EvaluationSource.lichess, 'Lichess'),
  ];
}

/// The Expectimax settings that are not changed from one search to the
/// next, shown in the tab where its results are: the method, the opponent's
/// rating, how many of our moves are searched, which replies are, and what
/// scores a position. Written to the same settings Settings ▸ Expectimax
/// shows. While a search runs they are shown, not changed: a search keeps
/// the settings it started with.
class SearchSettingsView extends StatelessWidget {
  const SearchSettingsView({
    super.key,
    required this.settings,
    required this.locked,
    required this.onProblem,
  });

  final SettingsStore settings;

  /// A search is running.
  final bool locked;

  /// What is typed cannot be taken, in words for the status line; null
  /// once it can.
  final ValueChanged<String?> onProblem;

  void _change(ExpectimaxOptions Function(ExpectimaxOptions now) edit) =>
      unawaited(
        settings.update(
          settings.value.copyWith(expectimax: edit(settings.value.expectimax)),
        ),
      );

  Widget _number(
    (String, String) copy, {
    required int value,
    required int min,
    required int max,
    required ValueChanged<int> onChanged,
    bool orZero = false,
  }) => _SettingLine(
    copy: copy,
    control: SearchNumberBox(
      name: copy.$1,
      value: value,
      min: min,
      max: max,
      orZero: orZero,
      enabled: !locked,
      onChanged: (n) => onChanged(n!),
      onProblem: onProblem,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final s = settings.value;
    final e = s.expectimax;
    return ListView(
      padding: const EdgeInsets.fromLTRB(Space.m, 0, Space.m, Space.m),
      children: [
        SizedBox(
          height: searchStatusHeight,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              locked ? 'Pause the search to change these.' : '',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ),
        _Segments<SearchMethod>(
          name: 'Method',
          options: [for (final m in SearchMethod.values) (m, m.label)],
          value: e.method,
          onChanged: locked
              ? null
              : (m) => _change((o) => o.copyWith(method: m)),
        ),
        if (e.method == SearchMethod.practical) ...[
          const SizedBox(height: Space.s),
          _number(
            SearchSettingCopy.rating,
            value: s.opponentElo,
            min: Settings.minElo,
            max: Settings.maxElo,
            onChanged: (n) => unawaited(
              settings.update(settings.value.copyWith(opponentElo: n)),
            ),
          ),
          _number(
            SearchSettingCopy.rootMoves,
            value: e.rootMoves,
            min: 1,
            max: ExpectimaxOptions.maxMoves,
            onChanged: (n) => _change((o) => o.copyWith(rootMoves: n)),
          ),
          _number(
            SearchSettingCopy.candidateMoves,
            value: e.candidateMoves,
            min: 1,
            max: ExpectimaxOptions.maxMoves,
            onChanged: (n) => _change((o) => o.copyWith(candidateMoves: n)),
          ),
          _number(
            SearchSettingCopy.rare,
            value: e.rareOnceIn,
            min: 2,
            max: ExpectimaxOptions.maxRareOnceIn,
            orZero: true,
            onChanged: (n) => _change((o) => o.copyWith(rareOnceIn: n)),
          ),
          _number(
            SearchSettingCopy.evalDepth,
            value: e.evalDepth,
            min: ExpectimaxOptions.minEvalDepth,
            max: ExpectimaxOptions.maxEvalDepth,
            onChanged: (n) => _change((o) => o.copyWith(evalDepth: n)),
          ),
          const _SettingLine(copy: SearchSettingCopy.source),
          _Segments<EvaluationSource>(
            name: SearchSettingCopy.source.$1,
            options: SearchSettingCopy.sources,
            value: e.source,
            onChanged: locked
                ? null
                : (source) => _change((o) => o.copyWith(source: source)),
          ),
        ],
      ],
    );
  }
}

/// A setting's name over its one line, with its box at the row's end.
class _SettingLine extends StatelessWidget {
  const _SettingLine({required this.copy, this.control});

  final (String, String) copy;
  final Widget? control;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: settingRowHeight),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Space.xs),
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(copy.$1, style: text.bodyMedium),
                  const SizedBox(height: Space.xs),
                  Text(copy.$2, style: text.labelSmall),
                ],
              ),
            ),
            if (control case final control?) ...[
              const SizedBox(width: Space.m),
              control,
            ],
          ],
        ),
      ),
    );
  }
}

/// Two or three choices side by side, as wide as the pane.
class _Segments<T extends Object> extends StatelessWidget {
  const _Segments({
    required this.name,
    required this.options,
    required this.value,
    required this.onChanged,
  });

  final String name;
  final List<(T, String)> options;
  final T value;

  /// Null while the choice cannot be changed.
  final ValueChanged<T>? onChanged;

  @override
  Widget build(BuildContext context) => Semantics(
    label: name,
    child: SegmentedButton<T>(
      segments: [
        for (final (value, label) in options)
          ButtonSegment(
            value: value,
            label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
      ],
      selected: {value},
      showSelectedIcon: false,
      style: const ButtonStyle(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: Space.s),
        ),
      ),
      onSelectionChanged: onChanged == null
          ? null
          : (chosen) => onChanged!(chosen.first),
    ),
  );
}

/// A number typed into a box and taken as it is typed, so a search started
/// straight after uses it. What cannot be taken is said through
/// [onProblem] and leaves the setting as it was; leaving the box puts the
/// setting's value back.
///
/// With [empty], the words an empty box shows, no number is a value too.
class SearchNumberBox extends StatefulWidget {
  const SearchNumberBox({
    super.key,
    required this.name,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    required this.onProblem,
    this.enabled = true,
    this.orZero = false,
    this.label,
    this.empty,
    this.width = settingNumberWidth,
  });

  /// What the number is, for the problem's words and a screen reader.
  final String name;
  final int? value;
  final int min;
  final int max;

  /// Zero is taken as well as [min] to [max].
  final bool orZero;
  final bool enabled;

  /// The name written on the box's border, where no row names it.
  final String? label;
  final String? empty;
  final double width;
  final ValueChanged<int?> onChanged;
  final ValueChanged<String?> onProblem;

  @override
  State<SearchNumberBox> createState() => _SearchNumberBoxState();
}

class _SearchNumberBoxState extends State<SearchNumberBox> {
  late final _box = TextEditingController(text: _shown);
  final _focus = FocusNode();

  String get _shown => widget.value?.toString() ?? '';

  String get _range =>
      '${widget.name}: ${widget.min} to ${widget.max}'
      '${widget.orZero ? ', or 0' : ''}'
      '${widget.empty == null ? '' : ', or empty'}';

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
  }

  @override
  void didUpdateWidget(SearchNumberBox old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value && !_focus.hasFocus) _box.text = _shown;
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocus);
    _focus.dispose();
    _box.dispose();
    super.dispose();
  }

  void _onFocus() {
    if (_focus.hasFocus || !mounted) return;
    if (_box.text != _shown) {
      _box.text = _shown;
      widget.onProblem(null);
    }
  }

  void _typed(String text) {
    if (!mounted) return;
    final trimmed = text.trim();
    final typed = int.tryParse(trimmed);
    final taken = trimmed.isEmpty
        ? widget.empty != null
        : typed != null &&
              (typed >= widget.min && typed <= widget.max ||
                  widget.orZero && typed == 0);
    widget.onProblem(taken ? null : _range);
    if (taken && typed != widget.value) widget.onChanged(typed);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return SizedBox(
      width: widget.width,
      child: Semantics(
        label: widget.label == null ? widget.name : null,
        child: TextField(
          controller: _box,
          focusNode: _focus,
          enabled: widget.enabled,
          textAlign: TextAlign.center,
          style: monoText.copyWith(color: text.bodyMedium?.color),
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          onChanged: _typed,
          decoration: InputDecoration(
            isDense: true,
            labelText: widget.label,
            hintText: widget.empty,
            hintStyle: text.bodySmall,
            floatingLabelBehavior: FloatingLabelBehavior.always,
            // Room under a name on the border for the number to sit clear.
            contentPadding: EdgeInsets.symmetric(
              horizontal: Space.xs,
              vertical: widget.label == null ? Space.s : Space.m,
            ),
            border: const OutlineInputBorder(),
          ),
        ),
      ),
    );
  }
}
