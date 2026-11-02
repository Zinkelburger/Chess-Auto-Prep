import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'problem_line.dart';
import 'progress_line.dart';
import 'theme.dart';

/// The one shape of a dialog that asks for something and then does it: a
/// title, the fields, the line that says what could not be done, and Cancel
/// on the left of the one filled button that does it.
///
/// Enter does what the filled button does whenever it can be pressed: from
/// a one-line field after the field has taken what was typed (a number, a
/// picked suggestion), and with nothing focused. A field of several lines
/// keeps Enter for its new line, and a focused button or toggle keeps it
/// for itself, so Enter on a focused Cancel cancels. Escape and a click
/// outside are Cancel.
///
/// While [busy] the dialog waits for its work: the progress line runs, the
/// filled button is off, and Escape and a click outside do nothing. Cancel
/// is off too unless [onCancel] stops the work, and then it says so
/// (`Stop`).
class FormDialog extends StatefulWidget {
  const FormDialog({
    super.key,
    required this.title,
    required this.body,
    required this.confirm,
    required this.onConfirm,
    this.confirmIcon,
    this.width = dialogNarrow,
    this.problem,
    this.problemAction,
    this.canFail = false,
    this.busy = false,
    this.working = false,
    this.progress,
    this.cancel = 'Cancel',
    this.onCancel,
  });

  final String title;

  /// The fields. A body taller than the window scrolls itself; one that
  /// holds a list gives it a fixed height.
  final Widget body;

  /// What the filled button says: the action, as in `Save player`.
  final String confirm;

  /// Null while the action cannot be taken, which turns the button off.
  final VoidCallback? onConfirm;

  /// The verb's symbol, for a confirm whose verb has one (`Run`).
  final IconData? confirmIcon;

  /// One of [dialogNarrow], [dialogMedium] or [dialogWide]; null for a
  /// body that sizes itself, such as the board editor.
  final double? width;

  /// What could not be done, under the fields, with its one fix.
  final String? problem;
  final Widget? problemAction;

  /// The dialog may say a problem, so the line for it is held empty from
  /// the start and the buttons do not move when one appears.
  final bool canFail;

  final bool busy;

  /// Something is being read that the dialog need not wait for, such as a
  /// preview: the progress line runs, nothing else changes.
  final bool working;

  /// How far [busy] work has got, 0 to 1, when that is known.
  final double? progress;

  /// What the left button says; null leaves only the filled one, for a
  /// dialog whose work is done and whose filled button now says `Done`.
  final String? cancel;

  /// What the left button does instead of closing the dialog, such as
  /// stopping a download; it stays on while [busy].
  final VoidCallback? onCancel;

  @override
  State<FormDialog> createState() => _FormDialogState();
}

class _FormDialogState extends State<FormDialog> {
  final _focus = FocusNode(debugLabel: 'Form dialog', skipTraversal: true);
  ModalRoute<Object?>? _route;

  @override
  void initState() {
    super.initState();
    // With no field asking for focus, the dialog itself takes it, so Enter
    // reaches it. Checked once the fields' own autofocus has settled.
    Timer.run(() {
      if (mounted && !_focus.hasFocus && (_route?.isCurrent ?? false)) {
        _focus.requestFocus();
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  bool get _canConfirm => !widget.busy && widget.onConfirm != null;

  /// Confirms once the frame after a field's own Enter is built, so the
  /// button pressed is the one that field's value left on; nothing when
  /// that Enter already closed the dialog or set it working.
  void _confirmAfterFrame() {
    SchedulerBinding.instance
      ..addPostFrameCallback((_) {
        if (!mounted || !(_route?.isCurrent ?? false) || !_canConfirm) {
          return;
        }
        widget.onConfirm!();
      })
      ..scheduleFrame();
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent ||
        (event.logicalKey != LogicalKeyboardKey.enter &&
            event.logicalKey != LogicalKeyboardKey.numpadEnter)) {
      return KeyEventResult.ignored;
    }
    final keys = HardwareKeyboard.instance;
    if (keys.isShiftPressed ||
        keys.isControlPressed ||
        keys.isAltPressed ||
        keys.isMetaPressed ||
        !_canConfirm) {
      return KeyEventResult.ignored;
    }
    final focus = FocusManager.instance.primaryFocus;
    if (identical(focus, _focus)) {
      widget.onConfirm!();
      return KeyEventResult.handled;
    }
    final field = focus?.context
        ?.findAncestorStateOfType<EditableTextState>()
        ?.widget;
    if (field == null || field.maxLines != 1) return KeyEventResult.ignored;
    field.onSubmitted?.call(field.controller.text);
    _confirmAfterFrame();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final busy = widget.busy;
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ProgressLine(
          active: busy || widget.working,
          value: busy ? widget.progress : null,
        ),
        Flexible(child: widget.body),
        if (widget.canFail || widget.problem != null)
          ProblemLine(widget.problem, action: widget.problemAction),
      ],
    );
    final onCancel = widget.onCancel;
    final icon = widget.confirmIcon;
    return PopScope(
      canPop: !busy,
      child: Focus(
        focusNode: _focus,
        onKeyEvent: _key,
        child: AlertDialog(
          title: Text(widget.title),
          content: widget.width == null
              ? content
              : SizedBox(width: widget.width, child: content),
          actions: [
            if (widget.cancel case final cancel?)
              TextButton(
                onPressed: onCancel ?? (busy ? null : () => _pop(context)),
                child: Text(cancel),
              ),
            if (icon == null)
              FilledButton(
                onPressed: _canConfirm ? widget.onConfirm : null,
                child: Text(widget.confirm),
              )
            else
              FilledButton.icon(
                onPressed: _canConfirm ? widget.onConfirm : null,
                icon: Icon(icon, size: IconSize.action),
                label: Text(widget.confirm),
              ),
          ],
        ),
      ),
    );
  }

  void _pop(BuildContext context) => Navigator.of(context).pop();
}
