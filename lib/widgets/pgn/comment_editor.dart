/// Inline PGN comment editor shared by every movetext surface.
///
/// The PGN viewer ([PgnMovetextView]) and the repertoire builder / study
/// editor ([InteractivePgnEditor]) both render this widget in the move flow
/// when a comment is being edited, so commenting looks and behaves the same
/// everywhere: a rounded field with save (✓) and cancel (✕), Enter to save.
library;

import 'package:flutter/material.dart';

class PgnCommentEditor extends StatefulWidget {
  final String initialText;
  final ValueChanged<String> onSave;
  final VoidCallback onCancel;

  const PgnCommentEditor({
    super.key,
    required this.initialText,
    required this.onSave,
    required this.onCancel,
  });

  @override
  State<PgnCommentEditor> createState() => _PgnCommentEditorState();
}

class _PgnCommentEditorState extends State<PgnCommentEditor> {
  late TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.grey.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _controller,
              autofocus: true,
              maxLines: null,
              style: TextStyle(fontSize: 13, color: Colors.grey[200]),
              decoration: InputDecoration(
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 4,
                ),
                border: InputBorder.none,
                hintText: 'Comment',
                hintStyle: TextStyle(color: Colors.grey[600], fontSize: 13),
              ),
              onSubmitted: (v) => widget.onSave(v),
            ),
          ),
          IconButton(
            onPressed: () => widget.onSave(_controller.text),
            icon: Icon(Icons.check, size: 18, color: Colors.grey[400]),
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            tooltip: 'Save comment',
          ),
          IconButton(
            onPressed: widget.onCancel,
            icon: Icon(Icons.close, size: 18, color: Colors.grey[500]),
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            tooltip: 'Cancel',
          ),
        ],
      ),
    );
  }
}
