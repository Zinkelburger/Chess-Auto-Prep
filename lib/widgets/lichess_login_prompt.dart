/// Shared "you need a Lichess account" affordances.
///
/// Lichess put the opening explorer behind a login in 2026 (anti-abuse):
/// anonymous requests to `explorer.lichess.ovh` come back `401`, and the API
/// spec now declares `security: OAuth2` on `/masters`, `/lichess` and
/// `/player`. Every surface that reads the opening database therefore has to
/// be able to say *that*, and offer the fix, instead of blaming the network.
///
/// [LichessLoginButton] is the single implementation of the browser
/// hand-off — start the PKCE flow, open the system browser, wait on the
/// local callback, report success. [LichessLoginPrompt] wraps it in the
/// empty-state copy a panel shows in place of the data it could not load.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/lichess_auth_service.dart';
import '../theme/app_colors.dart';

/// Button that hands off to Lichess in the browser and reports the outcome.
///
/// The label says *open* rather than *log in* because that is what pressing
/// it does — the account page is a web page, not a form in this app. While
/// the browser is open the authorize URL is shown with a copy button, so a
/// failed `launchUrl` (no default browser, a sandboxed session, a headless
/// remote desktop) leaves the user a way through instead of a dead end, and
/// a Cancel appears — [LichessAuthService.waitForCallback] otherwise blocks
/// for five minutes with no way out.
class LichessLoginButton extends StatefulWidget {
  const LichessLoginButton({
    super.key,
    this.onLoggedIn,
    this.label = 'Open Lichess to log in',
    this.expand = false,
  });

  /// Called once the token is stored — the caller re-runs whatever failed.
  final VoidCallback? onLoggedIn;

  final String label;

  /// Stretch to the available width (panel empty states) rather than hug the
  /// label (inline rows).
  final bool expand;

  @override
  State<LichessLoginButton> createState() => _LichessLoginButtonState();
}

class _LichessLoginButtonState extends State<LichessLoginButton> {
  bool _inProgress = false;
  bool _failed = false;
  bool _copied = false;

  /// The authorize URL of the flow in progress — kept so it can be copied,
  /// and kept after a failure so a retry is not the only way to get it back.
  String? _authUrl;

  Timer? _copiedTimer;

  /// Bumped on every start and on cancel, so a hand-off the user walked away
  /// from cannot come back five minutes later and repaint this button.
  int _flowSeq = 0;

  @override
  void dispose() {
    _copiedTimer?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    final auth = LichessAuthService.instance;
    final seq = ++_flowSeq;
    setState(() {
      _inProgress = true;
      _failed = false;
      _copied = false;
      _authUrl = null;
    });

    bool ok = false;
    try {
      final url = await auth.startOAuthFlow();
      if (!mounted || seq != _flowSeq) return;
      setState(() => _authUrl = url);
      await LichessAuthService.openUrl(url);
      ok = await auth.waitForCallback();
    } catch (_) {
      ok = false;
    }

    if (!mounted || seq != _flowSeq) return;
    setState(() {
      _inProgress = false;
      _failed = !ok;
    });
    if (ok) widget.onLoggedIn?.call();
  }

  Future<void> _cancel() async {
    // Reset first, tear down after: closing the callback server takes a few
    // event-loop turns, and the button should not sit on "Waiting for
    // browser…" through them. Orphaning the flow keeps the abandoned
    // waitForCallback from reporting a failure the user chose.
    _flowSeq++;
    setState(() {
      _inProgress = false;
      _failed = false;
      _authUrl = null;
    });
    await LichessAuthService.instance.cancelOAuthFlow();
  }

  Future<void> _copyUrl() async {
    final url = _authUrl;
    if (url == null) return;
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    setState(() => _copied = true);
    _copiedTimer?.cancel();
    _copiedTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: widget.expand ? double.infinity : null,
          height: 32,
          child: FilledButton.icon(
            onPressed: _inProgress ? null : _start,
            icon: _inProgress
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.open_in_new, size: 16),
            label: Text(
              _inProgress ? 'Waiting for browser…' : widget.label,
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ),
        if (_authUrl != null) _buildLinkFallback(),
        if (_inProgress)
          TextButton(
            onPressed: _cancel,
            child: const Text('Cancel', style: TextStyle(fontSize: 11)),
          ),
        if (_failed)
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text(
              'Login did not complete. Try again, or paste a personal '
              'access token in App settings → Accounts.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11,
                color: AppColors.onSurfaceMuted,
                height: 1.3,
              ),
            ),
          ),
      ],
    );
  }

  /// The escape hatch: the exact URL the browser was asked to open, with a
  /// copy button. The URL itself is never rendered in full — it carries a
  /// PKCE challenge and is a screenful of query string — so the copy button
  /// is the affordance, not the text.
  Widget _buildLinkFallback() {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            "Browser didn't open? Copy the link and paste it there.",
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11,
              color: AppColors.onSurfaceMuted,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 4),
          TextButton.icon(
            onPressed: _copyUrl,
            icon: Icon(_copied ? Icons.check : Icons.copy, size: 14),
            label: Text(
              _copied ? 'Link copied' : 'Copy login link',
              style: const TextStyle(fontSize: 11),
            ),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 28),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ],
      ),
    );
  }
}

/// Empty state shown in place of opening-database content when Lichess
/// rejects the request for want of an account.
class LichessLoginPrompt extends StatelessWidget {
  const LichessLoginPrompt({
    super.key,
    required this.message,
    this.title = 'Lichess login needed',
    this.onLoggedIn,
    this.compact = false,
  });

  /// One line on what specifically is unavailable without the account.
  final String message;

  final String title;

  /// Re-run the failed lookup once the user is logged in.
  final VoidCallback? onLoggedIn;

  /// Drop the icon and tighten the padding, for short panes.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(compact ? 12 : 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 280),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!compact) ...[
                const Icon(
                  Icons.lock_outline,
                  size: 28,
                  color: AppColors.onSurfaceMuted,
                ),
                const SizedBox(height: 10),
              ],
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.inkSoft,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.onSurfaceMuted,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 12),
              LichessLoginButton(expand: true, onLoggedIn: onLoggedIn),
            ],
          ),
        ),
      ),
    );
  }
}
