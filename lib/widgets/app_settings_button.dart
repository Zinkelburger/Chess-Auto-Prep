import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/app_state.dart';
import '../screens/settings_screen.dart';
import 'settings/settings_navigation.dart';

/// Opens shared preferences, including navigation to every view's settings.
Future<void> openAppSettings(
  BuildContext context, {
  AppMode? initialMode,
  int initialChapter = 0,
  int initialGlobalSection = 0,
}) async {
  final app = context.read<AppState>();
  final registry = ViewSettingsRegistry.forApp(app);
  await Navigator.push<void>(
    context,
    MaterialPageRoute<void>(
      builder: (_) => SettingsScreen(
        initialMode: initialMode,
        initialChapter: initialChapter,
        initialGlobalSection: initialGlobalSection,
      ),
    ),
  );
  registry.entries[app.currentMode]?.onClosed?.call();
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

  ViewSettingsRegistry? _registry;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _registry = ViewSettingsRegistry.forApp(context.read<AppState>());
    _register();
  }

  @override
  void didUpdateWidget(AppSettingsButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mode != widget.mode) {
      _registry?.unregister(oldWidget.mode, this);
    }
    _register();
  }

  void _register() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _registry?.register(
        widget.mode,
        this,
        widget.contentBuilder,
        widget.onClosed,
      );
    });
  }

  @override
  void dispose() {
    _registry?.unregister(widget.mode, this);
    super.dispose();
  }

  Future<void> _open() async {
    if (!mounted || _opening) return;
    _opening = true;
    try {
      await openAppSettings(context, initialMode: widget.mode);
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
