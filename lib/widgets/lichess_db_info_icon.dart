/// Small status icon next to Lichess database controls.
///
/// Logged out: an ⓘ that opens a popover explaining Lichess DB access with a
/// one-click OAuth login. Logged in: a subdued check whose popover shows who
/// is logged in and where to manage the account (App settings → Accounts —
/// stated as text, never a navigation: this popover opens from inside
/// dialogs, and pushing a settings screen over a settings dialog is exactly
/// the nesting the per-surface dialogs exist to avoid). Always visible
/// either way, so login state is readable at a glance.
library;

import 'package:flutter/material.dart';

import '../services/lichess_auth_service.dart';
import '../theme/app_colors.dart';
import 'lichess_login_prompt.dart';

class LichessDbInfoIcon extends StatelessWidget {
  const LichessDbInfoIcon({super.key, this.size = 14});

  final double size;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: LichessAuthService.instance,
      builder: (context, _) {
        final auth = LichessAuthService.instance;
        return IconButton(
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          iconSize: size,
          splashRadius: 24,
          icon: Icon(
            auth.isLoggedIn ? Icons.check_circle_outline : Icons.info_outline,
            size: size,
            color: auth.isLoggedIn
                ? AppColors.successMuted
                : AppColors.onSurfaceMuted,
          ),
          tooltip: auth.isLoggedIn
              ? 'Lichess: logged in as ${auth.username ?? 'unknown'}'
              : 'Lichess database info',
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
  @override
  Widget build(BuildContext context) {
    // Dark-only app: popover chrome comes straight from the shared palette.
    const bgColor = AppColors.surfaceContainer;
    const textColor = AppColors.inkSoft;

    final loggedIn = LichessAuthService.instance.isLoggedIn;
    final username = LichessAuthService.instance.username;

    return Stack(
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onDismiss,
          child: const SizedBox.expand(),
        ),
        Positioned(
          left: (widget.anchor.left - 180).clamp(
            8.0,
            MediaQuery.sizeOf(context).width - 280,
          ),
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
                  const Text(
                    'Lichess Database',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: textColor,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    loggedIn
                        ? 'Logged in as ${username ?? 'unknown'} — database '
                              'queries are enabled.'
                        : 'Database features require a Lichess account. '
                              'Log in to enable database queries.',
                    style: const TextStyle(
                      fontSize: 12,
                      color: textColor,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (loggedIn)
                    const Text(
                      'Log out or switch account in App settings → Accounts.',
                      style: TextStyle(
                        fontSize: 11,
                        color: AppColors.onSurfaceMuted,
                        height: 1.3,
                      ),
                    )
                  else
                    LichessLoginButton(
                      expand: true,
                      onLoggedIn: widget.onDismiss,
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
