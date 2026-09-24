import 'dart:async';

import 'package:flutter/material.dart';

import '../../storage/settings_store.dart';
import '../../ui/app_action.dart';
import '../../ui/search_field.dart';
import '../../ui/theme.dart';
import 'setting_controls.dart';
import 'setting_rows.dart';

/// Opens the settings over the workspace. Every change has already
/// happened by the time it closes; the close button, Esc or outside click dismisses it.
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
/// place on the right. Search spans both category names and individual rows.
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
    final theme = Theme.of(context);
    return Dialog(
      backgroundColor: theme.colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(readingCardRadius),
        side: BorderSide(color: theme.colorScheme.outline),
      ),
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
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    Space.l,
                    0,
                    Space.l,
                    Space.m,
                  ),
                  child: SearchField(
                    controller: _search,
                    hint: 'Search settings',
                    onChanged: _searched,
                  ),
                ),
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
                const Divider(height: 1),
                if (widget.store.problem case final problem?)
                  _Problem(problem)
                else
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: Space.l,
                      vertical: Space.s,
                    ),
                    child: Text(
                      'Changes save automatically',
                      style: theme.textTheme.labelSmall,
                    ),
                  ),
                if (widget.store.canRetry && widget.store.problem != null)
                  TextButton(
                    onPressed: () => unawaited(widget.store.retry()),
                    child: const Text('Retry save'),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _places(List<SettingGroup> groups) => ListView(
    padding: const EdgeInsets.all(Space.s),
    children: [
      for (final (index, group) in groups.indexed)
        _Place(
          name: group.name,
          selected: _query.isEmpty && index == _selected,
          onTap: () {
            if (!mounted) return;
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
    final shown = groups.isEmpty
        ? <SettingGroup>[]
        : _query.isEmpty
        ? [groups[_selected.clamp(0, groups.length - 1)]]
        : [
            for (final group in groups)
              if (group.name.toLowerCase().contains(_query) ||
                  group.rows.any((row) => row.matches(_query)))
                SettingGroup(group.name, [
                  for (final row in group.rows)
                    if (group.name.toLowerCase().contains(_query) ||
                        row.matches(_query))
                      row,
                ]),
          ];
    final text = Theme.of(context).textTheme;
    if (shown.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(Space.l),
        child: Text(
          groups.isEmpty
              ? 'No settings available.'
              : 'Nothing matches "$_query".',
          style: text.bodySmall,
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(Space.l, Space.m, Space.l, Space.m),
      children: [
        for (final group in shown) ...[
          Text(group.name.toUpperCase(), style: text.labelSmall),
          const SizedBox(height: Space.xs),
          for (final (index, row) in group.rows.indexed) ...[
            if (index > 0) const Divider(height: 1),
            SettingRowView(
              key: ValueKey('${group.name}/${row.label}'),
              row: row,
            ),
          ],
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
          tooltip: withKey('Close', 'Esc'),
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
    final icon = switch (name) {
      'Look' => Icons.palette_outlined,
      'Engine' => Icons.memory_outlined,
      'Repertoire' => Icons.menu_book_outlined,
      'Files' => Icons.folder_outlined,
      'Accounts' => Icons.person_outline,
      'App' => Icons.settings_outlined,
      _ => Icons.tune,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.xs),
      child: Semantics(
        selected: selected,
        button: true,
        child: Material(
          borderRadius: BorderRadius.circular(readingCardRadius),
          color: selected
              ? scheme.primary.withValues(alpha: 0.12)
              : Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(readingCardRadius),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Space.m,
                vertical: Space.m,
              ),
              child: Row(
                children: [
                  Icon(
                    icon,
                    size: IconSize.action,
                    color: selected ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: Space.s),
                  Expanded(
                    child: Text(
                      name,
                      style: TextStyle(
                        color: selected ? scheme.primary : scheme.onSurface,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
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
