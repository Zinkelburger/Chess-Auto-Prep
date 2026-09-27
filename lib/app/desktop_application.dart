import 'dart:async';
import 'package:flutter/material.dart';
import '../features/documents/controllers/document_close_coordinator.dart';
import '../features/documents/repositories/desktop_close_port.dart';
import '../features/documents/widgets/document_close_scope.dart';
import '../infrastructure/desktop/window_close_adapter.dart';
import '../l10n/generated/app_localizations.dart';
import 'themed_application.dart';

/// One native close policy surrounds every route and retained workspace.
class DesktopApplication extends StatefulWidget {
  const DesktopApplication({
    super.key,
    required this.home,
    this.builder,
    this.closePort,
  });
  final Widget home;
  final TransitionBuilder? builder;
  final DesktopClosePort? closePort;
  @override
  State<DesktopApplication> createState() => _DesktopApplicationState();
}

class _DesktopApplicationState extends State<DesktopApplication> {
  final _navigator = GlobalKey<NavigatorState>();
  final _documents = DocumentCloseCoordinator();
  late final _port = widget.closePort ?? WindowCloseAdapter();
  Future<void>? _closing;
  late final Future<void> _attached;
  @override
  void initState() {
    super.initState();
    _attached = _port.attach(() => unawaited(_requestClose()));
    unawaited(
      _attached.catchError((Object error) async {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(_showFailure(unavailable: true));
        });
      }),
    );
  }

  Future<void> _requestClose() =>
      _closing ??= _close().whenComplete(() => _closing = null);
  Future<void> _close() async {
    try {
      await _attached;
      final result = await _documents.prepareClose();
      if (!mounted) return;
      switch (result.disposition) {
        case DocumentCloseDisposition.approved:
          await _port.close();
        case DocumentCloseDisposition.cancelled:
          return;
        case DocumentCloseDisposition.changed:
          await _showFailure(changed: true);
        case DocumentCloseDisposition.failed:
          await _showFailure();
      }
    } catch (_) {
      if (mounted) await _showFailure();
    }
  }

  Future<void> _showFailure({
    bool changed = false,
    bool unavailable = false,
  }) async {
    final context = _navigator.currentState?.overlay?.context;
    if (context == null || !mounted) return;
    final l10n = AppLocalizations.of(context);
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.closeApplicationTitle),
        content: Text(
          unavailable
              ? l10n.windowCloseUnavailable
              : changed
              ? l10n.documentChangedWhileClosing
              : l10n.documentCloseFailed,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.keepApplicationOpen),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _documents.dispose();
    unawaited(
      _attached
          .then(
            (_) => _port.detach(),
            onError: (Object _, StackTrace _) => _port.detach(),
          )
          .catchError((Object error) {
            debugPrint('Could not detach native close policy: $error');
          }),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => DocumentCloseScope(
    coordinator: _documents,
    child: ThemedApplication(
      navigatorKey: _navigator,
      home: widget.home,
      builder: widget.builder,
    ),
  );
}
