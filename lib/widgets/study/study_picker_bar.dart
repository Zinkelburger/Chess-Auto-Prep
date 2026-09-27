/// Study switcher in the app bar: current name (inline rename), picker,
/// with study-wide operations in the app bar’s Actions menu.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import '../../l10n/generated/app_localizations.dart';
import 'package:flutter/services.dart';

import '../../features/studies/controllers/study_controller.dart';
import '../../features/studies/models/study_projection.dart';
import '../../features/studies/widgets/study_selector.dart';
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
  Object? _editingSession;
  String? _editingPath;
  final TextEditingController _nameEditController = TextEditingController();

  @override
  void dispose() {
    _nameEditController.dispose();
    super.dispose();
  }

  void _startNameEdit() {
    if (!mounted) return;
    final title = widget.study.title;
    _editingSession = title.session;
    _editingPath = title.filePath;
    _nameEditController.text = title.name;
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
    final title = widget.study.title;
    if (title.session != _editingSession ||
        title.filePath != _editingPath ||
        safe.isEmpty ||
        safe == title.name) {
      return;
    }
    try {
      await widget.study.renameStudy(safe);
    } on ArgumentError {
      if (mounted) {
        showAppSnackBar(
          context,
          AppLocalizations.of(context).studyNameExists,
          isError: true,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => StudySelector<StudyTitle>(
    study: widget.study,
    select: (study) => study.title,
    builder: _buildTitle,
  );

  Widget _buildTitle(BuildContext context, StudyTitle current) {
    final theme = Theme.of(context);
    final canRename = current.canRename;
    final isExternal = current.filePath != null && !canRename;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_editingName)
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
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
            ),
          )
        else
          Flexible(
            child: Tooltip(
              message: canRename
                  ? AppLocalizations.of(context).studyRename
                  : '',
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
          ),
        if (canRename && !_editingName)
          IconButton(
            icon: const Icon(Icons.edit_outlined, size: 16),
            tooltip: AppLocalizations.of(context).studyRename,
            visualDensity: VisualDensity.compact,
            onPressed: _startNameEdit,
          ),
        IconButton(
          icon: const Icon(Icons.arrow_drop_down, size: 22),
          tooltip: AppLocalizations.of(context).studySwitch,
          visualDensity: VisualDensity.compact,
          onPressed: widget.onPickStudy,
        ),
      ],
    );
  }
}
