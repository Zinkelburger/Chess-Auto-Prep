import 'dart:async';

import 'package:flutter/material.dart';

import '../services/opening_catalog.dart';
import '../theme/app_text_styles.dart';
import 'chess_board_widget.dart';
import 'common/list_search_field.dart';

class OpeningSelection {
  const OpeningSelection({this.lines = const [], this.positionLine});
  final List<CatalogOpening> lines;
  final CatalogOpening? positionLine;
}

Future<OpeningSelection?> showOpeningPicker(
  BuildContext context, {
  bool forFilters = false,
  Set<String> initialEcoCodes = const {},
}) => showDialog<OpeningSelection>(
  context: context,
  builder: (_) => OpeningPickerDialog(
    forFilters: forFilters,
    initialEcoCodes: initialEcoCodes,
  ),
);

/// Shared opening search; edits remain local until an explicit action is used.
class OpeningPickerDialog extends StatefulWidget {
  const OpeningPickerDialog({
    super.key,
    this.forFilters = false,
    this.openings,
    this.initialEcoCodes = const {},
  });
  final bool forFilters;
  final Set<String> initialEcoCodes;
  final Future<List<CatalogOpening>>? openings;

  @override
  State<OpeningPickerDialog> createState() => _OpeningPickerDialogState();
}

class _OpeningPickerDialogState extends State<OpeningPickerDialog> {
  late final _loading = widget.openings ?? OpeningCatalog.load();
  String _query = '';
  final _moves = TextEditingController();
  final _selected = <CatalogOpening>{};
  final _drafts = <CatalogOpening, String>{};
  CatalogOpening? _focused;
  CatalogOpening? _preview;
  String? _error;
  bool _flipped = false;

  @override
  void initState() {
    super.initState();
    if (widget.initialEcoCodes.isNotEmpty) {
      unawaited(
        _loading.then(
          (openings) {
            if (!mounted) return;
            final remaining = {...widget.initialEcoCodes};
            setState(() {
              for (final opening in openings) {
                if (remaining.remove(opening.eco)) _selected.add(opening);
              }
            });
          },
          onError: (Object _, StackTrace _) {
            // The results pane owns the catalog load error.
          },
        ),
      );
    }
  }

  @override
  void dispose() {
    _moves.dispose();
    super.dispose();
  }

  void _focus(CatalogOpening opening) {
    setState(() {
      _focused = opening;
      _moves.text = _drafts[opening] ?? opening.movetext;
      _updatePreview(_moves.text);
    });
  }

  void _updatePreview(String text) {
    final opening = _focused!;
    _drafts[opening] = text;
    try {
      _preview = CatalogOpening(
        eco: opening.eco,
        name: opening.name,
        moves: CatalogOpening.parseMoves(text),
      );
      _error = null;
    } on FormatException catch (e) {
      _preview = null;
      _error = e.message;
    }
  }

  void _finishLines() {
    final lines = <CatalogOpening>[];
    for (final opening in _selected) {
      try {
        lines.add(
          CatalogOpening(
            eco: opening.eco,
            name: opening.name,
            moves: CatalogOpening.parseMoves(
              _drafts[opening] ?? opening.movetext,
            ),
          ),
        );
      } on FormatException {
        _focus(opening);
        return;
      }
    }
    Navigator.pop(context, OpeningSelection(lines: lines));
  }

  @override
  Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.all(20),
    child: SizedBox(
      width: 1050,
      height: 740,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Choose openings by ECO',
                    style: AppTextStyles.title,
                  ),
                ),
                IconButton(
                  tooltip: 'Close opening picker',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const Text(
              'Search codes or names. Select named lines; one code can contain several positions.',
              style: AppTextStyles.muted,
            ),
            const SizedBox(height: 12),
            ListSearchField(
              key: const ValueKey('opening-search'),
              hintText: 'Search ECO codes or opening names',
              fillColor: Theme.of(context).colorScheme.surface,
              autofocus: true,
              onChanged: (query) {
                if (!mounted) return;
                setState(() => _query = query);
              },
            ),
            const SizedBox(height: 12),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final list = _buildResults();
                  final preview = _buildPreview();
                  return constraints.maxWidth >= 700
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(child: list),
                            const SizedBox(width: 16),
                            Expanded(child: preview),
                          ],
                        )
                      : Column(
                          children: [
                            Expanded(child: list),
                            const Divider(),
                            Expanded(flex: 2, child: preview),
                          ],
                        );
                },
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: [
                if (widget.forFilters)
                  OutlinedButton(
                    onPressed: _preview == null
                        ? null
                        : () => Navigator.pop(
                            context,
                            OpeningSelection(positionLine: _preview),
                          ),
                    child: const Text('Use preview position'),
                  ),
                FilledButton(
                  onPressed: _selected.isEmpty
                      ? null
                      : widget.forFilters
                      ? () => Navigator.pop(
                          context,
                          OpeningSelection(lines: _selected.toList()),
                        )
                      : _finishLines,
                  child: Text(
                    widget.forFilters
                        ? 'Filter by selected ECO codes (${_selected.map((e) => e.eco).toSet().length})'
                        : 'Add starting lines (${_selected.length})',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );

  Widget _buildResults() => FutureBuilder<List<CatalogOpening>>(
    future: _loading,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return const Center(
          child: Text('Could not load openings. Close and try again.'),
        );
      }
      if (!snapshot.hasData) {
        return const Center(child: CircularProgressIndicator());
      }
      final words = _query.toLowerCase().trim().split(RegExp(r'\s+'));
      final matches = snapshot.data!.where((entry) {
        final text = '${entry.eco} ${entry.name}'.toLowerCase();
        return words.every(text.contains);
      }).toList();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${matches.length} named lines · ${_selected.length} selected',
                  style: AppTextStyles.caption,
                ),
              ),
              TextButton(
                onPressed: _selected.isEmpty
                    ? null
                    : () => setState(_selected.clear),
                child: const Text('Clear selection'),
              ),
            ],
          ),
          Expanded(
            child: matches.isEmpty
                ? const Center(child: Text('No openings match this search.'))
                : ListView.builder(
                    itemCount: matches.length,
                    itemBuilder: (context, index) {
                      final entry = matches[index];
                      return ListTile(
                        selected: identical(entry, _focused),
                        leading: Checkbox(
                          value: _selected.contains(entry),
                          onChanged: (checked) {
                            if (!mounted) return;
                            setState(() {
                              checked == true
                                  ? _selected.add(entry)
                                  : _selected.remove(entry);
                            });
                            if (checked == true) _focus(entry);
                          },
                        ),
                        title: Text(
                          '${entry.eco} · ${entry.name}',
                          style: AppTextStyles.body,
                        ),
                        subtitle: Text(
                          entry.movetext,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AppTextStyles.caption,
                        ),
                        onTap: () {
                          if (mounted) _focus(entry);
                        },
                      );
                    },
                  ),
          ),
        ],
      );
    },
  );

  Widget _buildPreview() {
    final focused = _focused;
    if (focused == null) {
      return const Center(
        child: Text('Choose a line to preview its position.'),
      );
    }
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${focused.eco} · ${focused.name}',
            style: AppTextStyles.bodyStrong,
          ),
          const SizedBox(height: 8),
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: AspectRatio(
                aspectRatio: 1,
                child: ChessBoardWidget(
                  position: (_preview ?? focused).position,
                  flipped: _flipped,
                  enableUserMoves: _preview != null,
                  onMove: (move) {
                    if (!mounted || _preview == null) return;
                    final next = CatalogOpening(
                      eco: focused.eco,
                      name: focused.name,
                      moves: [..._preview!.moves, move.san],
                    );
                    setState(() {
                      _moves.text = next.movetext;
                      _updatePreview(_moves.text);
                    });
                  },
                ),
              ),
            ),
          ),
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: () => setState(() => _flipped = !_flipped),
                child: const Text('Flip board'),
              ),
              TextButton(
                onPressed: _preview == null || _preview!.moves.isEmpty
                    ? null
                    : () {
                        setState(() {
                          _moves.text = CatalogOpening(
                            eco: focused.eco,
                            name: focused.name,
                            moves: _preview!.moves.sublist(
                              0,
                              _preview!.moves.length - 1,
                            ),
                          ).movetext;
                          _updatePreview(_moves.text);
                        });
                      },
                child: const Text('Undo last move'),
              ),
              TextButton(
                onPressed: () {
                  setState(() {
                    _moves.text = focused.movetext;
                    _updatePreview(_moves.text);
                  });
                },
                child: const Text('Reset line'),
              ),
            ],
          ),
          TextField(
            key: const ValueKey('opening-moves'),
            controller: _moves,
            minLines: 2,
            maxLines: 5,
            style: AppTextStyles.mono,
            decoration: InputDecoration(
              labelText: 'Editable starting moves',
              errorText: _error,
              errorMaxLines: 2,
              border: const OutlineInputBorder(),
            ),
            onChanged: (text) {
              if (mounted) setState(() => _updatePreview(text));
            },
          ),
          const SizedBox(height: 8),
          Text(
            widget.forFilters
                ? 'Move edits apply to the position search. ECO filtering uses the original codes. You can arrange pieces with Set up a board after applying the position.'
                : 'Play on the board or edit the moves. Tick this line to include it in the build.',
            style: AppTextStyles.caption,
          ),
        ],
      ),
    );
  }
}
