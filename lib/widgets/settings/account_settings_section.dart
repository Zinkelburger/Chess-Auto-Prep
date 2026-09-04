/// The two account-shaped settings sections, deliberately kept apart.
///
/// [LichessLoginSection] is authentication: it proves you own a Lichess
/// account, raising API rate limits and unlocking private study import.
/// [ChessUsernamesSection] is just *whose games to download* — plain text,
/// no login, and it covers Chess.com too. Stacking them in one "Accounts"
/// card read as one setting with four controls; they are two unrelated
/// things that happen to both mention Lichess.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../services/lichess_auth_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import '../accounts/accounts_dialog.dart';
import 'settings_widgets.dart';

class LichessLoginSection extends StatelessWidget {
  const LichessLoginSection({super.key});

  @override
  Widget build(BuildContext context) {
    return const SettingsGroup(
      title: 'Lichess login',
      icon: Icons.key_outlined,
      subtitle:
          'Optional. Signing in raises Lichess API rate limits and lets the '
          'app import your private studies.',
      children: [_LichessLoginTile()],
    );
  }
}

class ChessUsernamesSection extends StatelessWidget {
  const ChessUsernamesSection({super.key});

  @override
  Widget build(BuildContext context) {
    return const SettingsGroup(
      title: 'Your chess usernames',
      icon: Icons.person_outline,
      subtitle:
          'Whose games the app downloads — for the home game review, tactics '
          'mining and every "fetch games" form. No login needed.',
      children: [_UsernamesTile()],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Lichess login / logout
// ═══════════════════════════════════════════════════════════════════════════

class _LichessLoginTile extends StatefulWidget {
  const _LichessLoginTile();

  @override
  State<_LichessLoginTile> createState() => _LichessLoginTileState();
}

class _LichessLoginTileState extends State<_LichessLoginTile> {
  final _patController = TextEditingController();

  bool _oauthInProgress = false;
  bool _patFieldVisible = false;
  bool _patValidating = false;
  String? _patError;
  bool _loggingOut = false;

  @override
  void dispose() {
    _patController.dispose();
    super.dispose();
  }

  Future<void> _startOAuth() async {
    final auth = LichessAuthService.instance;
    setState(() {
      _oauthInProgress = true;
      _patError = null;
    });
    try {
      final url = await auth.startOAuthFlow();
      await LichessAuthService.openUrl(url);
      await auth.waitForCallback();
    } finally {
      if (mounted) setState(() => _oauthInProgress = false);
    }
  }

  Future<void> _cancelOAuth() async {
    await LichessAuthService.instance.cancelOAuthFlow();
    if (mounted) setState(() => _oauthInProgress = false);
  }

  Future<void> _savePat() async {
    final token = _patController.text.trim();
    if (token.isEmpty) return;
    setState(() {
      _patValidating = true;
      _patError = null;
    });
    final ok = await LichessAuthService.instance.setPersonalAccessToken(token);
    if (!mounted) return;
    setState(() {
      _patValidating = false;
      if (ok) {
        _patFieldVisible = false;
        _patController.clear();
      } else {
        _patError =
            'Lichess rejected that token. Check it was copied fully and '
            'has not been revoked.';
      }
    });
  }

  Future<void> _logout() async {
    setState(() => _loggingOut = true);
    await LichessAuthService.instance.logout();
    if (mounted) setState(() => _loggingOut = false);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: LichessAuthService.instance,
      builder: (context, _) {
        final auth = LichessAuthService.instance;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: auth.isLoggedIn ? _buildLoggedIn(auth) : _buildLoggedOut(),
        );
      },
    );
  }

  Widget _buildLoggedIn(LichessAuthService auth) {
    final detail = auth.isPat
        ? 'Personal access token'
        : auth.tokenExpiry != null
        ? 'Logged in until '
              '${auth.tokenExpiry!.toLocal().toString().split(' ').first}'
        : 'Logged in';
    return Row(
      children: [
        const Icon(
          Icons.check_circle_outline,
          size: 18,
          color: AppColors.success,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Lichess: logged in as ${auth.username ?? 'unknown'}',
                style: const TextStyle(fontSize: 13),
              ),
              Text(detail, style: AppTextStyles.caption),
            ],
          ),
        ),
        OutlinedButton(
          onPressed: _loggingOut ? null : _logout,
          child: Text(_loggingOut ? 'Logging out…' : 'Log out'),
        ),
      ],
    );
  }

  Widget _buildLoggedOut() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(
              Icons.person_off_outlined,
              size: 18,
              color: AppColors.onSurfaceMuted,
            ),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                'Lichess: not logged in',
                style: TextStyle(fontSize: 13),
              ),
            ),
            if (_oauthInProgress) ...[
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
              const Text('Waiting for browser…', style: AppTextStyles.caption),
              const SizedBox(width: 8),
              TextButton(onPressed: _cancelOAuth, child: const Text('Cancel')),
            ] else
              ElevatedButton.icon(
                onPressed: _startOAuth,
                icon: const Icon(Icons.login, size: 16),
                label: const Text('Log into Lichess'),
              ),
          ],
        ),
        if (_patFieldVisible) ...[
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: _patController,
                  obscureText: true,
                  enabled: !_patValidating,
                  style: const TextStyle(fontSize: 13),
                  decoration: InputDecoration(
                    labelText: 'Personal access token',
                    labelStyle: const TextStyle(fontSize: 12),
                    helperText:
                        'Create one at lichess.org/account/oauth/token '
                        'with the "Read preferences" and "Read private '
                        'studies" scopes.',
                    helperMaxLines: 2,
                    errorText: _patError,
                    errorMaxLines: 3,
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  onSubmitted: (_) => _savePat(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _patValidating ? null : _savePat,
                child: Text(_patValidating ? 'Checking…' : 'Save token'),
              ),
            ],
          ),
        ] else if (!_oauthInProgress)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => setState(() => _patFieldVisible = true),
              child: const Text(
                'Use a personal access token instead',
                style: TextStyle(fontSize: 12),
              ),
            ),
          ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Default usernames
// ═══════════════════════════════════════════════════════════════════════════

/// What is configured, and one button onto the form.
///
/// The boxes themselves live in [AccountsDialog], which the tactics home's
/// accounts card also opens: one form, whichever door you came through. There
/// used to be two copies of the same two fields with different commit rules —
/// this one saving on focus loss, the home card's per keystroke — which is how
/// "what did I set my username to" became a question with two answers.
class _UsernamesTile extends StatelessWidget {
  const _UsernamesTile();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final lichess = app.lichessUsername?.trim() ?? '';
    final chesscom = app.chesscomUsername?.trim() ?? '';
    final configured = [
      if (lichess.isNotEmpty) 'Lichess: $lichess',
      if (chesscom.isNotEmpty) 'Chess.com: $chesscom',
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Row(
        children: [
          Icon(
            configured.isEmpty
                ? Icons.person_off_outlined
                : Icons.check_circle_outline,
            size: 18,
            color: configured.isEmpty
                ? AppColors.onSurfaceMuted
                : AppColors.success,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              configured.isEmpty
                  ? 'No usernames set'
                  : configured.join('   ·   '),
              style: const TextStyle(fontSize: 13),
            ),
          ),
          OutlinedButton(
            onPressed: () => showAccountsDialog(context),
            child: Text(configured.isEmpty ? 'Set up…' : 'Change…'),
          ),
        ],
      ),
    );
  }
}
