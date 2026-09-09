/// Study switcher in the app bar: current name (inline rename), picker,
/// with study-wide operations in the app bar’s Actions menu.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/study_controller.dart';
import '../../utils/app_messages.dart';
import 'study_name_dialog.dart' show sanitizeStudyName;

class StudyPickerBar extends StatefulWidget {
  const StudyPickerBar({
    super.key,
    required this.study,
    required this.focusNode,
    required this.onPickStudy,
  });

  final StudyController study;
  final FocusNode focusNode;
  final VoidCallback onPickStudy;

  @override
  State<StudyPickerBar> createState() => _StudyPickerBarState();
}

class _StudyPickerBarState extends State<StudyPickerBar> {
  bool _editingName = false;
  final TextEditingController _nameEditController = TextEditingController();

  @override
  void dispose() {
    _nameEditController.dispose();
    super.dispose();
  }

  void _startNameEdit() {
    if (!mounted) return;
    _nameEditController.text = widget.study.doc.name;
    _nameEditController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _nameEditController.text.length,
    );
    setState(() => _editingName = true);
  }

  Future<void> _commitNameEdit() async {
    if (!mounted || !_editingName) return;
    setState(() => _editingName = false);
    final safe = sanitizeStudyName(_nameEditController.text);
    if (safe.isEmpty || safe == widget.study.doc.name) return;
    try {
      await widget.study.renameStudy(safe);
    } on ArgumentError catch (e) {
      if (mounted) {
        showAppSnackBar(context, e.message as String, isError: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = widget.study.doc;
    final knownPaths = widget.study.availableStudies
        .map((s) => s.filePath)
        .toSet();
    final isExternal =
        current.filePath != null && !knownPaths.contains(current.filePath);
    final canRename = current.filePath != null && !isExternal;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_editingName)
          SizedBox(
            width: 220,
            child: Focus(
              onKeyEvent: (node, event) {
                if (!mounted) return KeyEventResult.ignored;
                if (event is KeyDownEvent &&
                    event.logicalKey == LogicalKeyboardKey.escape) {
                  setState(() => _editingName = false);
                  widget.focusNode.requestFocus();
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              onFocusChange: (focused) {
                if (!focused) unawaited(_commitNameEdit());
              },
              child: TextField(
                controller: _nameEditController,
                autofocus: true,
                style: theme.textTheme.bodyMedium,
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                ),
                onSubmitted: (_) => _commitNameEdit(),
              ),
            ),
          )
        else
          Tooltip(
            message: canRename ? 'Rename study' : '',
            child: InkWell(
              onTap: canRename ? _startNameEdit : null,
              borderRadius: BorderRadius.circular(4),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 260),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 4,
                  ),
                  child: Text(
                    isExternal ? '${current.name} (set)' : current.name,
                    style: theme.textTheme.bodyMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
          ),
        if (canRename && !_editingName)
          IconButton(
            icon: const Icon(Icons.edit_outlined, size: 16),
            tooltip: 'Rename study',
            visualDensity: VisualDensity.compact,
            onPressed: _startNameEdit,
          ),
        IconButton(
          icon: const Icon(Icons.arrow_drop_down, size: 22),
          tooltip: 'Switch study',
          visualDensity: VisualDensity.compact,
          onPressed: widget.onPickStudy,
        ),
      ],
    );
  }
}
