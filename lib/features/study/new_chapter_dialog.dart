import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';

import '../../chess/fen.dart';
import '../../ui/file_names.dart';
import '../../ui/theme.dart';
import '../../workspace/board_editor.dart';

/// What the user asked for: a name, where the chapter starts, and which way
/// its board faces.
typedef NewChapter = ({String name, Fen root, Side? orientation});

/// Asks for a new chapter, or answers null when the user backed out.
///
/// The starting position and the orientation are asked for here because both
/// are written into the chapter as it is created: a chapter set up from a
/// position has no moves to work either of them out from later. `Position`
/// opens the board editor in the dialog, its FEN field the same position as
/// text; `Create` waits until a game could start from it.
Future<NewChapter?> showNewChapterDialog(BuildContext context) =>
    showDialog<NewChapter>(
      context: context,
      builder: (_) => const _NewChapterDialog(),
    );

enum _Start { initial, position }

enum _Facing {
  automatic(null),
  white(Side.white),
  black(Side.black);

  const _Facing(this.side);

  /// Null means the chapter takes the side to move in its starting position,
  /// which is what a problem set up by hand wants.
  final Side? side;
}

class _NewChapterDialog extends StatefulWidget {
  const _NewChapterDialog();

  @override
  State<_NewChapterDialog> createState() => _NewChapterDialogState();
}

class _NewChapterDialogState extends State<_NewChapterDialog> {
  final _name = TextEditingController();
  String? _nameProblem;
  var _start = _Start.initial;
  var _facing = _Facing.automatic;

  /// The position the editor holds, kept while `Initial` is chosen so it
  /// comes back with the editor; null while no game could start from it.
  Fen? _position = Fen.initial;

  /// Where the editor starts: what it last held, so switching away and
  /// back keeps the user's work.
  Fen _edited = Fen.initial;

  /// The form and the editor keep their state — the name field's focus, a
  /// position half set up, the tool in hand — when the window's width
  /// moves the editor from beside the form to under it, or back.
  final _formKey = GlobalKey();
  final _editorKey = GlobalKey();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _change(VoidCallback change) {
    if (mounted) setState(change);
  }

  /// The name is what the field holds without the spaces around it, which
  /// is what is checked and what is answered.
  void _create() {
    if (!mounted) return;
    final name = _name.text.trim();
    final problem = nameProblem(name);
    if (problem != null) return _change(() => _nameProblem = problem);
    final root = _start == _Start.initial ? Fen.initial : _position;
    if (root == null) return;
    Navigator.of(
      context,
    ).pop<NewChapter>((name: name, root: root, orientation: _facing.side));
  }

  Widget _nameField() => TextField(
    controller: _name,
    autofocus: true,
    decoration: InputDecoration(
      labelText: 'Chapter name',
      errorText: _nameProblem,
    ),
    onChanged: (_) {
      if (_nameProblem != null) _change(() => _nameProblem = null);
    },
    onSubmitted: (_) => _create(),
  );

  /// The name, the start and the orientation, in the width of a name
  /// dialog.
  Widget _form(BuildContext context) {
    final label = Theme.of(context).textTheme.labelSmall;
    return SizedBox(
      key: _formKey,
      width: nameDialogWidth,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _nameField(),
          const SizedBox(height: Space.l),
          Text('Start from', style: label),
          const SizedBox(height: Space.xs),
          SegmentedButton<_Start>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: _Start.initial, label: Text('Initial')),
              ButtonSegment(value: _Start.position, label: Text('Position')),
            ],
            selected: {_start},
            onSelectionChanged: (chosen) =>
                _change(() => _start = chosen.first),
          ),
          const SizedBox(height: Space.l),
          Text('Orientation', style: label),
          const SizedBox(height: Space.xs),
          SegmentedButton<_Facing>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: _Facing.automatic, label: Text('Automatic')),
              ButtonSegment(value: _Facing.white, label: Text('White')),
              ButtonSegment(value: _Facing.black, label: Text('Black')),
            ],
            selected: {_facing},
            onSelectionChanged: (chosen) =>
                _change(() => _facing = chosen.first),
          ),
        ],
      ),
    );
  }

  /// `Position` opens the editor beside the form, where the window has the
  /// width for both, and under it where it has not.
  @override
  Widget build(BuildContext context) {
    final editing = _start == _Start.position;
    final editor = BoardEditor(
      key: _editorKey,
      initial: _edited,
      onChanged: (fen) => _change(() {
        _position = fen;
        if (fen != null) _edited = fen;
      }),
    );
    final beside =
        MediaQuery.sizeOf(context).width >=
        nameDialogWidth + Space.xl + BoardEditor.width + dialogRoom;
    return AlertDialog(
      title: const Text('New chapter'),
      content: SingleChildScrollView(
        child: !editing
            ? _form(context)
            : beside
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _form(context),
                  const SizedBox(width: Space.xl),
                  editor,
                ],
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _form(context),
                  const SizedBox(height: Space.l),
                  editor,
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: editing && _position == null ? null : _create,
          child: const Text('Create'),
        ),
      ],
    );
  }
}
