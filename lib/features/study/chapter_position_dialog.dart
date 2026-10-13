import 'package:flutter/material.dart';
import '../../ui/field_row.dart';
import '../../ui/number_field.dart';
import '../../ui/theme.dart';

Future<int?> showChapterPosition(
  BuildContext context,
  int position,
  int count,
) => showDialog<int>(
  context: context,
  builder: (_) => _Position(position: position, count: count),
);

class _Position extends StatefulWidget {
  const _Position({required this.position, required this.count});
  final int position, count;
  @override
  State<_Position> createState() => _PositionState();
}

class _PositionState extends State<_Position> {
  int _position = 1;
  @override
  void initState() {
    super.initState();
    _position = widget.position;
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Move chapter'),
    content: SizedBox(
      width: nameDialogWidth,
      child: FieldRow(
        label: 'Position',
        child: NumberField(
          label: 'Position',
          value: _position,
          min: 1,
          max: widget.count,
          onChanged: (value) => setState(() => _position = value),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _position),
        child: const Text('Move'),
      ),
    ],
  );
}
