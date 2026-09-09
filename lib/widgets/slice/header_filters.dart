/// Shared spreadsheet-style header filters for PGN slice/search.
///
/// Both hosts render editable Field / Rule / Value rows. State and presets
/// remain owned by the supplied [SliceFilterController].
library;

import 'package:flutter/material.dart';

import '../../core/slice_filter_controller.dart';
import '../../models/pgn_filter_models.dart';
import '../../services/pgn_tree_core.dart'
    show PlayerNameMatchSummary, summarizePlayerNameMatches;
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import '../common/choice_field.dart';
import 'header_suggestions.dart';

final _ecoExact = RegExp(r'^[A-E]\d{2}$');

class HeaderFilters extends StatefulWidget {
  final SliceFilterController controller;

  /// Retains the dialog's quick-add buttons; rows use the same editor in both
  /// modes, including editable preset rows and an explicit matching rule.
  final bool simple;

  /// Source games for distinct header suggestions and their game counts.
  /// Pass a new list when the source collection changes.
  final List<GameRecord>? games;

  const HeaderFilters({
    super.key,
    required this.controller,
    this.games,
    this.simple = false,
  });

  @override
  State<HeaderFilters> createState() => _HeaderFiltersState();
}

class _HeaderFiltersState extends State<HeaderFilters> {
  late HeaderSuggestions _suggestions;

  SliceFilterController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _suggestions = HeaderSuggestions(widget.games ?? const []);
  }

  @override
  void didUpdateWidget(HeaderFilters oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.games, widget.games)) {
      _suggestions = HeaderSuggestions(widget.games ?? const []);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) {
        final wide =
            constraints.maxWidth >=
            460 * MediaQuery.textScalerOf(context).scale(14) / 14;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (controller.headerRows.length > 1) ...[
              Text(
                'Match all conditions',
                style: AppTextStyles.forTheme(
                  context,
                  AppTextStyles.bodyStrong,
                ),
              ),
              const SizedBox(height: 8),
            ],
            if (wide && controller.headerRows.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _columns(
                  Text(
                    'Field',
                    style: AppTextStyles.forTheme(
                      context,
                      AppTextStyles.bodyStrong,
                    ),
                  ),
                  Text(
                    'Rule',
                    style: AppTextStyles.forTheme(
                      context,
                      AppTextStyles.bodyStrong,
                    ),
                  ),
                  Text(
                    'Value',
                    style: AppTextStyles.forTheme(
                      context,
                      AppTextStyles.bodyStrong,
                    ),
                  ),
                  const SizedBox(width: 44),
                ),
              ),
            for (var i = 0; i < controller.headerRows.length; i++)
              _buildRow(i, wide: wide),
            _buildAddButtons(),
          ],
        );
      },
    ),
  );

  Widget _columns(Widget field, Widget rule, Widget value, Widget remove) =>
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(flex: 3, child: field),
          const SizedBox(width: 8),
          Expanded(flex: 4, child: rule),
          const SizedBox(width: 8),
          Expanded(flex: 5, child: value),
          remove,
        ],
      );

  String _fieldLabel(String field) => switch (field) {
    kPlayerHeaderField => 'Player',
    'Date' => 'Date / year',
    'WhiteElo' => 'White rating',
    'BlackElo' => 'Black rating',
    'StudyRating' => 'Study rating',
    'StudySummary' => 'Study summary',
    'Site' => 'Place',
    _ => field,
  };

  String _ruleLabel(String field, MatchMode mode) => switch (mode) {
    MatchMode.contains => 'Contains',
    MatchMode.notContains => 'Does not contain',
    MatchMode.exact => 'Exact',
    MatchMode.regex => 'Matches regex',
    MatchMode.after => field == 'Date' ? 'In or after' : 'At least',
    MatchMode.before => field == 'Date' ? 'In or before' : 'At most',
  };

  void _addField(String field) {
    if (!mounted) return;
    controller.addHeaderRow();
    final index = controller.headerRows.length - 1;
    controller.setHeaderField(index, field);
    if (field == 'Result') controller.setHeaderMode(index, MatchMode.exact);
  }

  Widget _buildAddButtons() => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      if (!widget.simple)
        TextButton.icon(
          onPressed: () => _addField(kPlayerHeaderField),
          icon: const Icon(Icons.add, size: 16),
          label: const Text('Add condition'),
        ),
      if (widget.simple) ...[
        for (final field in [
          kPlayerHeaderField,
          'Event',
          'Date',
          'Result',
          'Opening',
        ])
          TextButton(
            onPressed: () => _addField(field),
            child: Text(field == 'Date' ? 'Year' : field),
          ),
        PopupMenuButton<String>(
          tooltip: 'More filters',
          onSelected: _addField,
          itemBuilder: (_) => [
            for (final field in kHeaderFieldOptions)
              PopupMenuItem(value: field, child: Text(_fieldLabel(field))),
          ],
          child: const Padding(
            padding: EdgeInsets.all(8),
            child: Text('More…'),
          ),
        ),
      ],
    ],
  );

  Widget _buildRow(int index, {required bool wide}) {
    final row = controller.headerRows[index];
    // Resolve the row at callback time: removing a preceding row must not
    // redirect a retained overlay callback to a different condition.
    void edit(void Function(int) action) {
      if (!mounted) return;
      final current = controller.headerRows.indexOf(row);
      if (current >= 0) action(current);
    }

    final field = _NewConditionFocus(
      focusOnMount: row.value.isEmpty && !widget.simple,
      child: ChoiceField<String>(
        label: wide ? null : 'Field',
        hint: 'Choose field',
        value: row.field,
        items: [
          for (final field in kHeaderFieldOptions)
            ChoiceItem(
              value: field,
              label: _fieldLabel(field),
              searchText: '$field ${_fieldLabel(field)}',
            ),
        ],
        onChanged: (field) => edit((i) => controller.setHeaderField(i, field)),
      ),
    );
    final rule = ChoiceField<MatchMode>(
      label: wide ? null : 'Rule',
      hint: 'Choose rule',
      value: row.mode,
      items: [
        for (final mode in modesForField(row.field))
          ChoiceItem(
            value: mode,
            label: _ruleLabel(row.field, mode),
            searchText: '${mode.name} ${_ruleLabel(row.field, mode)}',
          ),
      ],
      onChanged: (mode) => edit((i) => controller.setHeaderMode(i, mode)),
    );
    final value = _NewConditionFocus(
      focusOnMount: row.value.isEmpty && widget.simple,
      child: _HeaderValueEditor(
        // Refresh autocomplete when its source/rule changes. In particular,
        // choosing the same value again after switching rules must set Exact.
        key: ValueKey((row.controller, row.field, row.mode, _suggestions)),
        row: row,
        label: wide ? null : 'Value',
        suggestions: _suggestions,
        onChanged: (value) => edit((i) => controller.setHeaderValue(i, value)),
        onSelected: (value) => edit((i) {
          controller.setHeaderValue(i, value);
          controller.setHeaderMode(i, MatchMode.exact);
        }),
      ),
    );
    final remove = IconButton(
      tooltip: 'Remove filter',
      onPressed: () => edit(controller.removeHeaderRow),
      icon: const Icon(Icons.close, size: 20),
      constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
    );
    return Padding(
      key: ObjectKey(row),
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (wide)
            _columns(field, rule, value, remove)
          else ...[
            Row(
              children: [
                Expanded(child: field),
                const SizedBox(width: 8),
                Expanded(child: rule),
                remove,
              ],
            ),
            const SizedBox(height: 8),
            value,
          ],
          if (widget.games != null &&
              row.field == kPlayerHeaderField &&
              row.mode == MatchMode.contains &&
              row.value.trim().isNotEmpty &&
              !row.hasMultiplePlayerNames)
            _buildNameMatchesLine(row.value),
        ],
      ),
    );
  }

  Widget _buildNameMatchesLine(String namesInput) {
    final summary = summarizePlayerNameMatches(
      headerPairs: [
        for (final g in widget.games!)
          (white: g.headers['White'] ?? '', black: g.headers['Black'] ?? ''),
      ],
      namesInput: namesInput,
    );
    return Padding(
      padding: const EdgeInsets.only(left: 4, top: 4),
      child: Text(
        _nameMatchesLabel(summary),
        style: AppTextStyles.forTheme(context, AppTextStyles.caption).copyWith(
          color: summary.matchedGames == 0
              ? Theme.of(context).colorScheme.error
              : Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  static String _nameMatchesLabel(PlayerNameMatchSummary summary) {
    if (summary.matchedGames == 0) return 'No games match this name';
    const maxShown = 8;
    final variants = summary.variantCounts.entries.toList();
    final shown = variants
        .take(maxShown)
        .map((e) => '${e.key} ×${e.value}')
        .join(' · ');
    final more = variants.length > maxShown
        ? ' (+${variants.length - maxShown} more)'
        : '';
    return 'Matches ${summary.matchedGames} of ${summary.totalGames} games '
        'as: $shown$more';
  }
}

/// Free text remains a filter; only explicitly picking an actual value makes
/// it exact. RawAutocomplete supplies keyboard navigation and dismissal.
class _HeaderValueEditor extends StatefulWidget {
  const _HeaderValueEditor({
    super.key,
    required this.row,
    required this.label,
    required this.suggestions,
    required this.onChanged,
    required this.onSelected,
  });

  final HeaderFilterRow row;
  final String? label;
  final HeaderSuggestions suggestions;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSelected;

  @override
  State<_HeaderValueEditor> createState() => _HeaderValueEditorState();
}

class _HeaderValueEditorState extends State<_HeaderValueEditor> {
  final _focus = FocusNode(debugLabel: 'Header filter value');
  final _optionsScroll = ScrollController();

  @override
  void dispose() {
    _focus.dispose();
    _optionsScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final showEcoWarn =
        row.field == 'ECO' &&
        row.mode == MatchMode.exact &&
        row.value.isNotEmpty &&
        !_ecoExact.hasMatch(row.value.trim());
    String? error = row.hasMultiplePlayerNames
        ? 'Use one player name per filter'
        : null;
    if (row.mode == MatchMode.regex && row.value.isNotEmpty) {
      try {
        RegExp(row.value, caseSensitive: false);
      } on FormatException {
        error = 'Invalid regular expression';
      }
    }
    return LayoutBuilder(
      builder: (context, constraints) => RawAutocomplete<HeaderSuggestion>(
        textEditingController: row.controller,
        focusNode: _focus,
        displayStringForOption: (option) => option.value,
        optionsBuilder: (value) =>
            widget.suggestions.matching(row.field, value.text),
        onSelected: (option) {
          if (!mounted) return;
          widget.onSelected(option.value);
        },
        fieldViewBuilder: (context, text, focus, submit) => TextField(
          controller: text,
          focusNode: focus,
          style: AppTextStyles.forTheme(context, AppTextStyles.body),
          decoration: InputDecoration(
            labelText: widget.label,
            errorText: error,
            errorMaxLines: 2,
            hintText: switch (row.field) {
              kPlayerHeaderField => 'Player name, either colour',
              'Date' => 'Year or date',
              'ECO' => 'ECO code or prefix',
              'WhiteElo' || 'BlackElo' || 'StudyRating' => 'Rating',
              _ => 'Type a value',
            },
            helperText: showEcoWarn ? 'Expected A00–E99' : null,
            helperMaxLines: 3,
            helperStyle: showEcoWarn
                ? AppTextStyles.forTheme(
                    context,
                    AppTextStyles.caption,
                  ).copyWith(color: Theme.of(context).colorScheme.error)
                : AppTextStyles.forTheme(context, AppTextStyles.caption),
            isDense: true,
            border: const OutlineInputBorder(),
          ),
          onChanged: (value) {
            if (!mounted) return;
            widget.onChanged(value);
          },
          onSubmitted: (_) {
            if (!mounted) return;
            submit();
          },
        ),
        optionsViewBuilder: (context, select, options) {
          final visible = options.toList();
          final highlighted = AutocompleteHighlightedOption.of(context);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || !_optionsScroll.hasClients) return;
            const itemHeight = 64.0;
            final top = highlighted * itemHeight;
            final bottom = top + itemHeight;
            final position = _optionsScroll.position;
            final offset = top < position.pixels
                ? top
                : bottom > position.pixels + position.viewportDimension
                ? bottom - position.viewportDimension
                : position.pixels;
            _optionsScroll.jumpTo(offset.clamp(0.0, position.maxScrollExtent));
          });
          return Align(
            alignment: Alignment.topLeft,
            child: Material(
              elevation: 6,
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(8),
              clipBehavior: Clip.antiAlias,
              child: SizedBox(
                width: constraints.maxWidth,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 260),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(10),
                        child: Text(
                          'Values in games · select for Exact',
                          style: AppTextStyles.forTheme(
                            context,
                            AppTextStyles.caption,
                          ),
                        ),
                      ),
                      Flexible(
                        child: ListView.builder(
                          controller: _optionsScroll,
                          itemExtent: 64,
                          shrinkWrap: true,
                          padding: EdgeInsets.zero,
                          itemCount: visible.length,
                          itemBuilder: (context, index) {
                            final option = visible[index];
                            return ListTile(
                              dense: true,
                              selected: index == highlighted,
                              selectedTileColor: AppColors.accent.withValues(
                                alpha: 0.14,
                              ),
                              title: Tooltip(
                                message: option.value,
                                child: Text(
                                  option.value,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTextStyles.forTheme(
                                    context,
                                    AppTextStyles.body,
                                  ),
                                ),
                              ),
                              subtitle: Text(
                                '${option.count} ${option.count == 1 ? 'game' : 'games'}',
                                style: AppTextStyles.forTheme(
                                  context,
                                  AppTextStyles.caption,
                                ),
                              ),
                              onTap: () {
                                if (!mounted) return;
                                select(option);
                              },
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// A new condition must take focus even when an existing row is being edited.
/// Keep this scope local to the choice so traversal can continue to its value.
class _NewConditionFocus extends StatefulWidget {
  const _NewConditionFocus({required this.focusOnMount, required this.child});

  final bool focusOnMount;
  final Widget child;

  @override
  State<_NewConditionFocus> createState() => _NewConditionFocusState();
}

class _NewConditionFocusState extends State<_NewConditionFocus> {
  final _scope = FocusScopeNode(
    debugLabel: 'PGN filter condition',
    traversalEdgeBehavior: TraversalEdgeBehavior.parentScope,
  );

  @override
  void initState() {
    super.initState();
    if (widget.focusOnMount) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        // The choice's input is now attached. Request it explicitly rather
        // than relying on autofocus, which preserves an already focused field.
        FocusTraversalGroup.of(
          context,
        ).findFirstFocus(_scope, ignoreCurrentFocus: true)?.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _scope.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      FocusScope(node: _scope, child: widget.child);
}
