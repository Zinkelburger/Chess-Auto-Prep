/// Small ⓘ icon that shows a popover explaining Lichess DB access and
/// offers a one-click OAuth login.  Hidden when already authenticated.
library;

import 'package:flutter/material.dart';

import '../services/lichess_auth_service.dart';

class LichessDbInfoIcon extends StatelessWidget {
  const LichessDbInfoIcon({super.key, this.size = 14});

  final double size;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: LichessAuthService(),
      builder: (context, _) {
        if (LichessAuthService().isLoggedIn) return const SizedBox.shrink();
        return IconButton(
          padding: EdgeInsets.zero,
          constraints: BoxConstraints(maxWidth: size + 8, maxHeight: size + 8),
          iconSize: size,
          splashRadius: size,
          icon: Icon(Icons.info_outline, size: size, color: Colors.grey[500]),
          tooltip: '',
          onPressed: () => _showInfoPopup(context),
        );
      },
    );
  }

  void _showInfoPopup(BuildContext context) {
    final overlay = Overlay.of(context);
    final renderBox = context.findRenderObject() as RenderBox;
    final offset = renderBox.localToGlobal(Offset.zero);
    final boxSize = renderBox.size;

    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) => _InfoPopupOverlay(
        anchor: offset & boxSize,
        onDismiss: () => entry.remove(),
      ),
    );
    overlay.insert(entry);
  }
}

class _InfoPopupOverlay extends StatefulWidget {
  const _InfoPopupOverlay({required this.anchor, required this.onDismiss});

  final Rect anchor;
  final VoidCallback onDismiss;

  @override
  State<_InfoPopupOverlay> createState() => _InfoPopupOverlayState();
}

class _InfoPopupOverlayState extends State<_InfoPopupOverlay> {
  bool _oauthInProgress = false;

  Future<void> _startLogin() async {
    final lichess = LichessAuthService();
    setState(() => _oauthInProgress = true);

    try {
      final url = await lichess.startOAuthFlow();
      LichessAuthService.openUrl(url);
      final success = await lichess.waitForCallback();
      if (mounted && success) {
        widget.onDismiss();
      } else if (mounted) {
        setState(() => _oauthInProgress = false);
      }
    } catch (_) {
      if (mounted) setState(() => _oauthInProgress = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF2A2A2E) : Colors.white;
    final textColor = isDark ? Colors.grey[300]! : Colors.grey[800]!;

    return Stack(
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onDismiss,
          child: const SizedBox.expand(),
        ),
        Positioned(
          left: (widget.anchor.left - 180).clamp(8.0, MediaQuery.of(context).size.width - 280),
          top: widget.anchor.bottom + 4,
          child: Material(
            elevation: 8,
            borderRadius: BorderRadius.circular(8),
            color: bgColor,
            child: Container(
              width: 260,
              padding: const EdgeInsets.all(12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Lichess Database',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: textColor,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Database features require a Lichess account. '
                    'Log in to enable database queries.',
                    style: TextStyle(fontSize: 12, color: textColor, height: 1.4),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    height: 32,
                    child: ElevatedButton.icon(
                      onPressed: _oauthInProgress ? null : _startLogin,
                      icon: _oauthInProgress
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.login, size: 16),
                      label: Text(
                        _oauthInProgress ? 'Waiting for browser...' : 'Log into Lichess',
                        style: const TextStyle(fontSize: 12),
                      ),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
