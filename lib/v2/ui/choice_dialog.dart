import 'package:flutter/material.dart';

import 'search_field.dart';
import 'theme.dart';

/// Asks the user to pick one of [options], answering null when they back out.
///
/// A menu of every repertoire is unusable once there are forty of them and
/// impossible to type into, so the list is searchable: the field filters the
/// labels as they are typed, and the enter key takes the one thing left when
/// only one is left. Nothing is preselected — a list that opens with a
/// highlight invites the enter key to pick whatever happens to be first.
Future<T?> showChoiceDialog<T extends Object>(
  BuildContext context, {
  required String title,
  required List<T> options,
  required String Function(T option) label,
  required String hint,
  required String empty,
}) => showDialog<T>(
  context: context,
  builder: (context) => _ChoiceDialog<T>(
    title: title,
    options: options,
    label: label,
    hint: hint,
    empty: empty,
  ),
);

class _ChoiceDialog<T extends Object> extends StatefulWidget {
  const _ChoiceDialog({
    required this.title,
    required this.options,
    required this.label,
    required this.hint,
    required this.empty,
  });

  final String title;
  final List<T> options;
  final String Function(T option) label;
  final String hint;

  /// What to say when there is nothing to pick from at all.
  final String empty;

  @override
  State<_ChoiceDialog<T>> createState() => _ChoiceDialogState<T>();
}

class _ChoiceDialogState<T extends Object> extends State<_ChoiceDialog<T>> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<T> get _matches {
    final needle = _query.trim().toLowerCase();
    if (needle.isEmpty) return widget.options;
    return [
      for (final option in widget.options)
        if (widget.label(option).toLowerCase().contains(needle)) option,
    ];
  }

  void _searched(String query) {
    if (!mounted) return;
    setState(() => _query = query);
  }

  /// Enter picks the one thing left, and does nothing while there is more
  /// than one: guessing between two repertoires is how a chapter ends up in
  /// the wrong one.
  void _submitted(String _) {
    final matches = _matches;
    if (matches.length == 1) _pick(matches.single);
  }

  void _pick(T option) => Navigator.of(context).pop(option);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: nameDialogWidth,
        height: choiceDialogHeight,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SearchField(
              controller: _search,
              hint: widget.hint,
              autofocus: true,
              onChanged: _searched,
              onSubmitted: _submitted,
            ),
            const SizedBox(height: Space.s),
            Expanded(child: _list(context)),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }

  Widget _list(BuildContext context) {
    final matches = _matches;
    if (matches.isEmpty) {
      return Text(
        widget.options.isEmpty ? widget.empty : 'Nothing matches "$_query".',
        style: Theme.of(context).textTheme.bodySmall,
      );
    }
    return ListView.builder(
      itemCount: matches.length,
      itemBuilder: (context, index) => ListTile(
        dense: true,
        title: Text(
          widget.label(matches[index]),
          overflow: TextOverflow.ellipsis,
        ),
        onTap: () => _pick(matches[index]),
      ),
    );
  }
}
