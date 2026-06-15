/// Shared header filters widget for PGN slice/search.
///
/// Renders a dynamic list of field/mode/value filter rows with add/remove.
library;

import 'package:flutter/material.dart';

import '../../models/pgn_filter_models.dart';

/// Mutable filter row used internally.
class HeaderFilterRow {
  String field;
  MatchMode mode;
  String value;
  final TextEditingController controller;

  HeaderFilterRow({
    this.field = 'Black',
    this.mode = MatchMode.contains,
    String initialValue = '',
  })  : value = initialValue,
        controller = TextEditingController(text: initialValue);

  HeaderFilterConfig toConfig() =>
      HeaderFilterConfig(field: field, mode: mode, value: value);
}

/// Available PGN header field options.
const kHeaderFieldOptions = [
  'White',
  'Black',
  'Event',
  'Result',
  'Date',
  'ECO',
  'Opening',
  'Site',
  'WhiteElo',
  'BlackElo',
  'StudyRating',
  'StudySummary',
];

/// Match modes available for a given field.
List<MatchMode> modesForField(String field) {
  if (field == 'Date' ||
      field == 'StudyRating' ||
      field == 'WhiteElo' ||
      field == 'BlackElo') {
    return MatchMode.values;
  }
  return [
    MatchMode.contains,
    MatchMode.notContains,
    MatchMode.exact,
    MatchMode.regex,
  ];
}

final _ecoExact = RegExp(r'^[A-E]\d{2}$');
bool _isValidEco(String value) => _ecoExact.hasMatch(value.trim());

/// Stateful widget managing a dynamic list of PGN header filter rows.
class HeaderFilters extends StatefulWidget {
  /// Called whenever a filter value changes (debounced by caller if needed).
  final VoidCallback onChanged;

  /// Pre-populate from existing config.
  final List<HeaderFilterConfig>? initialFilters;

  const HeaderFilters({
    super.key,
    required this.onChanged,
    this.initialFilters,
  });

  @override
  State<HeaderFilters> createState() => HeaderFiltersState();
}

class HeaderFiltersState extends State<HeaderFilters> {
  final List<HeaderFilterRow> _filters = [];

  /// Get current filter configs (non-empty values only).
  List<HeaderFilterConfig> get configs => _filters
      .where((f) => f.value.isNotEmpty)
      .map((f) => f.toConfig())
      .toList();

  /// Get raw filter data for slice computation.
  List<({String field, MatchMode mode, String value})> get rawFilters =>
      _filters
          .where((f) => f.value.isNotEmpty)
          .map((f) => (field: f.field, mode: f.mode, value: f.value))
          .toList();

  @override
  void initState() {
    super.initState();
    if (widget.initialFilters != null) {
      for (final f in widget.initialFilters!) {
        if (f.value.isEmpty) continue;
        _filters.add(HeaderFilterRow(
          field: kHeaderFieldOptions.contains(f.field) ? f.field : 'Black',
          mode: f.mode,
          initialValue: f.value,
        ));
      }
    }
    if (_filters.isEmpty) {
      _filters.add(HeaderFilterRow(field: 'Date', mode: MatchMode.after));
    }
  }

  @override
  void dispose() {
    for (final f in _filters) {
      f.controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Header Filters',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 14,
            color: Colors.grey[300],
          ),
        ),
        const SizedBox(height: 8),
        for (int i = 0; i < _filters.length; i++) _buildFilterRow(i),
        TextButton.icon(
          onPressed: _addFilter,
          icon: const Icon(Icons.add, size: 16),
          label: const Text('Add filter'),
        ),
      ],
    );
  }

  void _addFilter() {
    setState(() => _filters.add(HeaderFilterRow()));
  }

  void _removeFilter(int i) {
    setState(() {
      _filters[i].controller.dispose();
      _filters.removeAt(i);
    });
    widget.onChanged();
  }

  Widget _buildFilterRow(int index) {
    final f = _filters[index];
    final availableModes = modesForField(f.field);
    if (!availableModes.contains(f.mode)) {
      f.mode = availableModes.first;
    }

    String hintText;
    if (f.field == 'ECO') {
      hintText = 'e.g. B12 or B1';
    } else if (f.field == 'Date') {
      hintText = 'e.g. 2000';
    } else if (f.field == 'StudyRating') {
      hintText = 'e.g. 3';
    } else if (f.field == 'WhiteElo' || f.field == 'BlackElo') {
      hintText = 'e.g. 2400';
    } else {
      hintText = 'Value...';
    }

    final showEcoWarn = f.field == 'ECO' &&
        f.mode == MatchMode.exact &&
        f.value.isNotEmpty &&
        !_isValidEco(f.value);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              SizedBox(
                width: 120,
                child: DropdownButtonFormField<String>(
                  initialValue: f.field,
                  isDense: true,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    isDense: true,
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    border: OutlineInputBorder(),
                  ),
                  items: kHeaderFieldOptions
                      .map((s) => DropdownMenuItem(
                          value: s,
                          child: Text(s, style: const TextStyle(fontSize: 12))))
                      .toList(),
                  onChanged: (v) {
                    setState(() {
                      f.field = v!;
                      final modes = modesForField(f.field);
                      if (!modes.contains(f.mode)) {
                        f.mode = modes.first;
                      } else if (isNumericField(f.field) &&
                          f.mode == MatchMode.contains) {
                        f.mode = MatchMode.after;
                      }
                    });
                    if (f.value.isNotEmpty) widget.onChanged();
                  },
                ),
              ),
              const SizedBox(width: 6),
              SizedBox(
                width: 120,
                child: DropdownButtonFormField<MatchMode>(
                  initialValue: f.mode,
                  isDense: true,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    isDense: true,
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    border: OutlineInputBorder(),
                  ),
                  items: availableModes
                      .map((m) => DropdownMenuItem(
                            value: m,
                            child: Text(
                                matchModeLabel(m,
                                    numeric: isNumericField(f.field)),
                                style: const TextStyle(fontSize: 12)),
                          ))
                      .toList(),
                  onChanged: (v) {
                    setState(() => f.mode = v!);
                    if (f.value.isNotEmpty) widget.onChanged();
                  },
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: TextField(
                  controller: f.controller,
                  decoration: InputDecoration(
                    hintText: hintText,
                    hintStyle: TextStyle(color: Colors.grey[600], fontSize: 12),
                    isDense: true,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                    border: const OutlineInputBorder(),
                    suffixIcon: showEcoWarn
                        ? Tooltip(
                            message: 'Not a standard ECO code (A00–E99)',
                            child: Icon(Icons.warning_amber,
                                size: 16, color: Colors.orange[400]),
                          )
                        : null,
                    suffixIconConstraints:
                        const BoxConstraints(minWidth: 28, minHeight: 28),
                  ),
                  style: const TextStyle(fontSize: 12),
                  onChanged: (v) {
                    f.value = v;
                    widget.onChanged();
                  },
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                onPressed: () => _removeFilter(index),
                icon: const Icon(Icons.close, size: 18),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              ),
            ],
          ),
          if (showEcoWarn)
            Padding(
              padding: const EdgeInsets.only(left: 248, top: 2),
              child: Text(
                'Expected A00–E99',
                style: TextStyle(fontSize: 10, color: Colors.orange[400]),
              ),
            ),
        ],
      ),
    );
  }
}
