import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/app_state.dart';
import '../screens/settings_screen.dart';

/// Opens shared preferences, including navigation to every view's settings.
Future<void> openAppSettings(BuildContext context) async {
  final app = context.read<AppState>();
  final mode = await Navigator.push<AppMode>(
    context,
    MaterialPageRoute<AppMode>(builder: (_) => const SettingsScreen()),
  );
  if (context.mounted && mode != null) app.openViewSettings(mode);
}

/// Consistent trailing gear. Contextual content stays owned by its view.
/// A settings navigation request also works for a view not yet built by MainScreen.
class AppSettingsButton extends StatefulWidget {
  const AppSettingsButton({
    super.key,
    required this.mode,
    this.contentBuilder,
    this.onClosed,
  });

  final AppMode mode;
  final WidgetBuilder? contentBuilder;
  final VoidCallback? onClosed;

  @override
  State<AppSettingsButton> createState() => _AppSettingsButtonState();
}

class _AppSettingsButtonState extends State<AppSettingsButton> {
  bool _opening = false;

  Future<void> _open() async {
    if (!mounted || _opening) return;
    _opening = true;
    final app = context.read<AppState>();
    try {
      final mode = await Navigator.push<AppMode>(
        context,
        MaterialPageRoute<AppMode>(
          builder: (_) => SettingsScreen(
            initialMode: widget.mode,
            viewContentBuilder: widget.contentBuilder,
          ),
        ),
      );
      if (mounted) {
        if (mode != null) {
          app.openViewSettings(mode);
        } else {
          widget.onClosed?.call();
        }
      }
    } finally {
      _opening = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    if (app.settingsMode == widget.mode && app.currentMode == widget.mode) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !app.takeViewSettingsRequest(widget.mode)) return;
        unawaited(_open());
      });
    }
    return IconButton(
      key: ValueKey('view-settings-${widget.mode.name}'),
      icon: const Icon(Icons.settings_outlined, size: 20),
      tooltip: 'Settings',
      onPressed: _open,
    );
  }
}
