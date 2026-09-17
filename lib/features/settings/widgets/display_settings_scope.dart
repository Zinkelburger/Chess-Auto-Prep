import 'package:flutter/widgets.dart';
import '../controllers/board_display_settings.dart';
import '../models/board_display_configuration.dart';

class DisplaySettingsScope extends InheritedNotifier<BoardDisplaySettings> {
  const DisplaySettingsScope({
    super.key,
    required BoardDisplaySettings settings,
    required super.child,
  }) : super(notifier: settings);

  /// Bare board previews get an immutable default, never a mutable writer.
  static BoardDisplayConfiguration of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<DisplaySettingsScope>()
          ?.notifier
          ?.committed ??
      BoardDisplayConfiguration();
}
