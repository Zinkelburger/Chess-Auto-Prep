import 'package:flutter/material.dart';

import '../theme/app_text_styles.dart';
import '../utils/app_messages.dart';

/// A button that copies something, and says so.
///
/// One widget rather than the eighteen hand-rolled `Clipboard.setData` call
/// sites it replaces, because they had drifted into eighteen different answers
/// to the same two questions: whether pressing it tells you anything happened,
/// and what it looks like when it does. Some showed a snack bar, some showed
/// nothing at all, and the ones that showed nothing were indistinguishable
/// from a button that had not registered the press.
///
/// The feedback is *in the button*: the icon becomes a tick and the label
/// becomes "Copied" for a few seconds. That works where a snack bar does not —
/// inside a dialog, a popup menu, or a panel the user is about to scroll — and
/// it stays next to the thing that was copied, which is the question the user
/// actually has. [snackBarMessage] is there for the call sites that were
/// showing one already and whose button scrolls out of view.
///
/// [text] is a callback rather than a string because several call sites build
/// what they copy — a PGN, a FEN, a diagnostic report — and building it on
/// every rebuild to fill in a parameter that is only read on a press is waste
/// nobody intended.
class CopyButton extends StatefulWidget {
  const CopyButton({
    super.key,
    required this.text,
    this.label = 'Copy',
    this.icon = Icons.copy_all_outlined,
    this.tooltip,
    this.foreground,
    this.snackBarMessage,
    this.dense = false,
    this.iconSize,
    this.enabled = true,
  }) : _iconOnly = false;

  /// The same button with no label, for toolbars and list rows where the
  /// surrounding text already says what would be copied.
  const CopyButton.icon({
    super.key,
    required this.text,
    required String this.tooltip,
    this.icon = Icons.copy,
    this.foreground,
    this.snackBarMessage,
    this.dense = false,
    this.iconSize,
    this.enabled = true,
  }) : label = '',
       _iconOnly = true;

  /// What to copy, built when the button is pressed.
  final ValueGetter<String> text;

  /// Resting label. Becomes "Copied" while the confirmation shows.
  final String label;

  final IconData icon;

  /// Required for [CopyButton.icon], where nothing else names the action.
  final String? tooltip;

  /// Ink colour, for the banners and panels that set their own.
  final Color? foreground;

  /// Shown as a snack bar as well, for buttons that scroll away.
  final String? snackBarMessage;

  /// Tighter padding, for dense rows.
  final bool dense;

  /// Overrides the icon size, for the dense rows that had picked their own.
  /// Converting them was meant to change nothing on screen.
  final double? iconSize;

  /// False greys the button out — for the call sites where there is nothing to
  /// copy yet, such as an empty move path.
  final bool enabled;

  final bool _iconOnly;

  @override
  State<CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<CopyButton> {
  bool _copied = false;

  void _copy() {
    copyToClipboard(
      context,
      widget.text(),
      successMessage: widget.snackBarMessage,
    );
    setState(() => _copied = true);
    // Long enough to be read, short enough that a second copy is not blocked
    // by the confirmation of the first.
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final icon = Icon(
      _copied ? Icons.check : widget.icon,
      size: widget.iconSize ?? (widget.dense ? 16 : 18),
      color: widget.foreground,
    );

    if (widget._iconOnly) {
      return IconButton(
        onPressed: widget.enabled ? _copy : null,
        icon: icon,
        tooltip: _copied ? 'Copied' : widget.tooltip,
        padding: widget.dense ? EdgeInsets.zero : null,
        visualDensity: widget.dense ? VisualDensity.compact : null,
        color: widget.foreground,
      );
    }

    final label = Text(
      _copied ? 'Copied' : widget.label,
      style: AppTextStyles.caption.copyWith(color: widget.foreground),
    );
    final button = TextButton.icon(
      onPressed: widget.enabled ? _copy : null,
      icon: icon,
      label: label,
      style: TextButton.styleFrom(
        foregroundColor: widget.foreground,
        padding: EdgeInsets.symmetric(
          horizontal: widget.dense ? 8 : 12,
          vertical: widget.dense ? 4 : 8,
        ),
        minimumSize: Size.zero,
        tapTargetSize: widget.dense
            ? MaterialTapTargetSize.shrinkWrap
            : MaterialTapTargetSize.padded,
      ),
    );
    final tooltip = widget.tooltip;
    return tooltip == null ? button : Tooltip(message: tooltip, child: button);
  }
}
