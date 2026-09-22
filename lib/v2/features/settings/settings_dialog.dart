import 'package:flutter/material.dart';

import '../../storage/settings_store.dart';
import '../../ui/search_field.dart';
import '../../ui/theme.dart';
import 'setting_controls.dart';
import 'setting_rows.dart';

/// Opens the settings over the workspace. Every change has already
/// happened by the time it closes; Esc is the only way out.
Future<void> showSettingsDialog(
  BuildContext context, {
  required SettingsStore store,
  required List<SettingGroup> Function() groups,
  Listenable? also,
}) => showDialog<void>(
  context: context,
  builder: (context) =>
      SettingsDialog(store: store, groups: groups, also: also),
);

/// The settings: a list of places on the left, the rows of the chosen
/// place on the right, one line each. Small and fixed, so it is one glance
/// however many rows a place has; typing in the search shows the rows
/// that match from every place.
class SettingsDialog extends StatefulWidget {
  const SettingsDialog({
    super.key,
    required this.store,
    required this.groups,
    this.also,
  });

  final SettingsStore store;

  /// The rows as they are now; asked again on every change to the store,
  /// or to [also], the one other owner rows are built from.
  final List<SettingGroup> Function() groups;
  final Listenable? also;

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  final _search = TextEditingController();
  String _query = '';
  int _selected = 0;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _searched(String query) {
    if (!mounted) return;
    setState(() => _query = query.trim().toLowerCase());
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: SizedBox(
        width: settingsDialogWidth,
        height: settingsDialogHeight,
        child: ListenableBuilder(
          listenable: Listenable.merge([widget.store, ?widget.also]),
          builder: (context, _) {
            final groups = widget.groups();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _TitleBar(onClose: () => Navigator.of(context).pop()),
                const Divider(height: 1),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        width: settingsListWidth,
                        child: _places(groups),
                      ),
                      const VerticalDivider(width: 1),
                      Expanded(child: _rows(groups)),
                    ],
                  ),
                ),
                if (widget.store.problem case final problem?) _Problem(problem),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _places(List<SettingGroup> groups) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(Space.s, Space.s, Space.s, Space.xs),
        child: SearchField(
          controller: _search,
          hint: 'Find',
          onChanged: _searched,
        ),
      ),
      for (final (index, group) in groups.indexed)
        _Place(
          name: group.name,
          selected: _query.isEmpty && index == _selected,
          onTap: () {
            _search.clear();
            setState(() {
              _query = '';
              _selected = index;
            });
          },
        ),
    ],
  );

  /// The chosen place's rows, or every row the search finds under the name
  /// of its place.
  Widget _rows(List<SettingGroup> groups) {
    final shown = _query.isEmpty
        ? [groups[_selected.clamp(0, groups.length - 1)]]
        : [
            for (final group in groups)
              if (group.rows.any((row) => row.matches(_query)))
                SettingGroup(group.name, [
                  for (final row in group.rows)
                    if (row.matches(_query)) row,
                ]),
          ];
    final text = Theme.of(context).textTheme;
    if (shown.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(Space.l),
        child: Text('Nothing matches "$_query".', style: text.bodySmall),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(Space.l, Space.m, Space.l, Space.m),
      children: [
        for (final group in shown) ...[
          Text(group.name.toUpperCase(), style: text.labelSmall),
          const SizedBox(height: Space.xs),
          for (final row in group.rows) SettingRowView(row: row),
          const SizedBox(height: Space.m),
        ],
      ],
    );
  }
}

class _TitleBar extends StatelessWidget {
  const _TitleBar({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(Space.l, Space.xs, Space.xs, Space.xs),
    child: Row(
      children: [
        Expanded(
          child: Text(
            'Settings',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        IconButton(
          icon: const Icon(Icons.close, size: IconSize.action),
          tooltip: 'Close (Esc)',
          onPressed: onClose,
          visualDensity: VisualDensity.compact,
        ),
      ],
    ),
  );
}

class _Place extends StatelessWidget {
  const _Place({
    required this.name,
    required this.selected,
    required this.onTap,
  });

  final String name;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected ? scheme.surfaceContainerHighest : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Space.m,
            vertical: Space.s,
          ),
          child: Text(name),
        ),
      ),
    );
  }
}

class _Problem extends StatelessWidget {
  const _Problem(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.l, Space.s, Space.l, Space.s),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.error,
        ),
      ),
    );
  }
}
