import 'package:flutter/widgets.dart';

/// One thing the user can ask for by name: a menu entry, a button and a
/// key are ways to the same [run].
///
/// The shell gathers these from the workspace and the mode showing, so the
/// Actions menu is the same shape whatever is open and however it was
/// opened. An action with no [run] is shown but cannot be taken now.
@immutable
final class AppAction {
  const AppAction(
    this.label,
    this.run, {
    this.shortcut,
    this.group,
    this.icon,
    this.alternatives = const [],
  });

  final String label;

  /// Contextual destinations for actions that open a workspace tool.
  final List<AppAction> alternatives;

  /// Optional familiar symbol; the action keeps its text label.
  final IconData? icon;
  final VoidCallback? run;

  /// The key, in the words a tooltip uses: `Ctrl+S`, `F`. Null when none.
  final String? shortcut;

  /// Actions under one heading sit together; null puts one at the top.
  final String? group;

  /// The label with its key after it, the way a tooltip says it.
  String get labelWithKey => withKey(label, shortcut);
}

/// [description] with the key that does it after it — `Flip board (F)` —
/// the way every control with a key says so in its tooltip; [description]
/// alone when there is no key.
String withKey(String description, String? key) =>
    key == null ? description : '$description ($key)';
