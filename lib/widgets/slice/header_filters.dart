/// Shared header filters widget for PGN slice/search.
///
/// Renders a dynamic list of field/mode/value filter rows with add/remove.
/// All state lives on the [SliceFilterController] passed in by the host.
library;

import 'package:flutter/material.dart';

import '../../core/slice_filter_controller.dart';
import '../../models/pgn_filter_models.dart';

final _ecoExact = RegExp(r'^[A-E]\d{2}$');
bool _isValidEco(String value) => _ecoExact.hasMatch(value.trim());

class HeaderFilters extends StatelessWidget {
  final SliceFilterController controller;

  const HeaderFilters({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => Column(
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
          for (int i = 0; i < controller.headerRows.length; i++)
            _buildFilterRow(i),
          TextButton.icon(
            onPressed: controller.addHeaderRow,
            icon: const Icon(Icons.add, size: 16),
            label: const Text('Add filter'),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterRow(int index) {
    final f = controller.headerRows[index];
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

    final showEcoWarn =
        f.field == 'ECO' &&
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
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                    border: OutlineInputBorder(),
                  ),
                  items: kHeaderFieldOptions
                      .map(
                        (s) => DropdownMenuItem(
                          value: s,
                          child: Text(s, style: const TextStyle(fontSize: 12)),
                        ),
                      )
                      .toList(),
                  onChanged: (v) => controller.setHeaderField(index, v!),
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
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                    border: OutlineInputBorder(),
                  ),
                  items: availableModes
                      .map(
                        (m) => DropdownMenuItem(
                          value: m,
                          child: Text(
                            matchModeLabel(m, numeric: isNumericField(f.field)),
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (v) => controller.setHeaderMode(index, v!),
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
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 10,
                    ),
                    border: const OutlineInputBorder(),
                    suffixIcon: showEcoWarn
                        ? Tooltip(
                            message: 'Not a standard ECO code (A00–E99)',
                            child: Icon(
                              Icons.warning_amber,
                              size: 16,
                              color: Colors.orange[400],
                            ),
                          )
                        : null,
                    suffixIconConstraints: const BoxConstraints(
                      minWidth: 28,
                      minHeight: 28,
                    ),
                  ),
                  style: const TextStyle(fontSize: 12),
                  onChanged: (v) => controller.setHeaderValue(index, v),
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                onPressed: () => controller.removeHeaderRow(index),
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
