part of 'tactics_import_panel.dart';

/// Wraps [child] in a [Tooltip] only when [message] is non-null.
///
/// Avoid empty tooltip messages — Flutter's OverlayPortal-based tooltips can
/// assert if the message toggles between empty and non-empty during hover.
Widget _conditionalTooltip({required String? message, required Widget child}) {
  final text = message?.trim();
  if (text == null || text.isEmpty) return child;
  return Tooltip(message: text, child: child);
}
