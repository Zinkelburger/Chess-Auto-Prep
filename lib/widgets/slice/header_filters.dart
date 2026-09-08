/// Shared header filters widget for PGN slice/search.
///
/// Renders editable one-line conditions with searchable choices and add/remove.
/// All state lives on the [SliceFilterController] passed in by the host.
library;

import 'package:flutter/material.dart';

import '../../core/slice_filter_controller.dart';
import '../../models/pgn_filter_models.dart';
import '../common/choice_field.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import '../../services/pgn_tree_core.dart'
    show PlayerNameMatchSummary, summarizePlayerNameMatches;

final _ecoExact = RegExp(r'^[A-E]\d{2}$');
bool _isValidEco(String value) => _ecoExact.hasMatch(value.trim());

class HeaderFilters extends StatelessWidget {
  final SliceFilterController controller;

  /// When provided, [kPlayerHeaderField] rows show which header spellings
  /// their names currently match across these games (and how often), so the
  /// user can see e.g. "Carlsen, Magnus ×54 · Carlsen,M ×33" instead of
  /// trusting substring matching blind.
  final List<GameRecord>? games;

  const HeaderFilters({super.key, required this.controller, this.games});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (controller.headerRows.length > 1) ...[
            Text(
              'Match all conditions',
              style: AppTextStyles.subtitle.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
          ],
          for (int i = 0; i < controller.headerRows.length; i++)
            _buildFilterRow(context, i),
          OutlinedButton.icon(
            onPressed: () {
              if (!context.mounted) return;
              controller.addHeaderRow();
              controller.setHeaderField(
                controller.headerRows.length - 1,
                kPlayerHeaderField,
              );
            },
            style: OutlinedButton.styleFrom(
              visualDensity: VisualDensity.standard,
              minimumSize: const Size(0, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              padding: const EdgeInsets.symmetric(horizontal: 10),
            ),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Filter'),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterRow(BuildContext context, int index) {
    final f = controller.headerRows[index];
    // Hints say what the box wants, not what somebody else typed into it:
    // a sample name is one more thing to read past on the way to your own.
    String hintText;
    if (f.field == kPlayerHeaderField) {
      hintText = 'Name; another name';
    } else if (f.field == 'ECO') {
      hintText = 'ECO code or prefix';
    } else if (f.field == 'Date') {
      hintText = 'Year';
    } else if (f.field == 'StudyRating') {
      hintText = 'Rating';
    } else if (f.field == 'WhiteElo' || f.field == 'BlackElo') {
      hintText = 'Rating';
    } else {
      hintText = 'Value';
    }

    final showEcoWarn =
        f.field == 'ECO' &&
        f.mode == MatchMode.exact &&
        f.value.isNotEmpty &&
        !_isValidEco(f.value);

    return Padding(
      key: ObjectKey(f),
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _NewConditionFocus(
                  focusOnMount: f.value.isEmpty,
                  child: ChoiceField<({String field, MatchMode mode})>(
                    hint: 'Choose condition',
                    value: (field: f.field, mode: f.mode),
                    style: AppTextStyles.body,
                    items: [
                      for (final field in kHeaderFieldOptions)
                        for (final mode in modesForField(field))
                          ChoiceItem(
                            value: (field: field, mode: mode),
                            label: HeaderFilterConfig(
                              field: field,
                              mode: mode,
                              value: '',
                            ).conditionLabel,
                            searchText:
                                '$field ${mode.name} ${HeaderFilterConfig(field: field, mode: mode, value: '').conditionLabel}',
                          ),
                    ],
                    onChanged: (choice) {
                      if (!context.mounted) return;
                      controller.setHeaderField(index, choice.field);
                      controller.setHeaderMode(index, choice.mode);
                      FocusScope.of(context).nextFocus();
                    },
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  key: ObjectKey(f.controller),
                  controller: f.controller,
                  decoration: InputDecoration(
                    hintText: hintText,
                    hintStyle: AppTextStyles.hint,
                    helperText: f.field == kPlayerHeaderField
                        ? 'Either colour; separate names with ;'
                        : null,
                    isDense: true,
                    border: const OutlineInputBorder(),
                    suffixIcon: showEcoWarn
                        ? const Tooltip(
                            message: 'Not a standard ECO code (A00–E99)',
                            child: Icon(
                              Icons.warning_amber,
                              size: 20,
                              color: AppColors.warning,
                            ),
                          )
                        : null,
                  ),
                  style: AppTextStyles.body,
                  onChanged: (v) {
                    if (!context.mounted) return;
                    controller.setHeaderValue(index, v);
                  },
                ),
              ),
              IconButton(
                onPressed: () {
                  if (!context.mounted) return;
                  controller.removeHeaderRow(index);
                },
                tooltip: 'Remove filter',
                icon: const Icon(Icons.close, size: 20),
                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
              ),
            ],
          ),
          if (showEcoWarn)
            const Padding(
              padding: EdgeInsets.only(left: 4, top: 4),
              child: Text(
                'Expected A00–E99',
                style: TextStyle(fontSize: 12, color: AppColors.warning),
              ),
            ),
          if (_showsNameMatches(f)) _buildNameMatchesLine(f.value),
        ],
      ),
    );
  }

  /// Matched-spellings feedback only makes sense for substring name search;
  /// exact/regex/not-contains modes are left alone.
  bool _showsNameMatches(HeaderFilterRow f) =>
      games != null &&
      f.field == kPlayerHeaderField &&
      f.mode == MatchMode.contains &&
      f.value.trim().isNotEmpty;

  Widget _buildNameMatchesLine(String namesInput) {
    final summary = summarizePlayerNameMatches(
      headerPairs: [
        for (final g in games!)
          (white: g.headers['White'] ?? '', black: g.headers['Black'] ?? ''),
      ],
      namesInput: namesInput,
    );
    return Padding(
      padding: const EdgeInsets.only(left: 4, top: 2),
      child: Text(
        _nameMatchesLabel(summary),
        style: TextStyle(
          fontSize: 12,
          color: summary.matchedGames == 0
              ? AppColors.warning
              : AppColors.onSurfaceMuted,
        ),
      ),
    );
  }

  static String _nameMatchesLabel(PlayerNameMatchSummary summary) {
    if (summary.matchedGames == 0) {
      return 'No games match these names';
    }
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
