/// Settings section for the MCP agent bridge.
///
/// Off by default. Turning it on binds a loopback HTTP server and mints a
/// fresh bearer token, so an external agent (Cursor, Claude Code) can drive
/// tournament prep through the stdio shim in `tools/mcp/`.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../features/tournament/mcp/prep_server.dart';
import '../../features/tournament/services/tournament_session.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import 'settings_widgets.dart';

class AgentBridgeSection extends StatefulWidget {
  const AgentBridgeSection({super.key});

  @override
  State<AgentBridgeSection> createState() => _AgentBridgeSectionState();
}

class _AgentBridgeSectionState extends State<AgentBridgeSection> {
  PrepServer? _server;
  String? _endpointPath;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    unawaited(_server?.stop());
    super.dispose();
  }

  Future<void> _toggle(bool enable) async {
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      if (enable) {
        final server = PrepServer(context.read<TournamentSession>());
        final path = await server.start();
        if (!mounted) {
          await server.stop();
          return;
        }
        setState(() {
          _server = server;
          _endpointPath = path;
        });
      } else {
        await _server?.stop();
        if (!mounted) return;
        setState(() {
          _server = null;
          _endpointPath = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final running = _server?.isRunning ?? false;

    return SettingsGroup(
      title: 'Agent bridge (MCP)',
      icon: Icons.hub_outlined,
      children: [
        Text(
          'Lets Cursor or Claude Code drive tournament prep: import an entry '
          'list, search the web for players\' online accounts, and run the '
          'clash. The agent can propose accounts but never confirm them, and '
          'cannot write chess data.',
          style: AppTextStyles.caption,
        ),
        const SizedBox(height: 12),
        SwitchListTile(
          value: running,
          onChanged: _busy ? null : _toggle,
          contentPadding: EdgeInsets.zero,
          title: const Text('Accept agent connections'),
          subtitle: Text(
            running
                ? 'Listening on 127.0.0.1:${_server!.port} — loopback only.'
                : 'Off. No port is open.',
            style: AppTextStyles.caption,
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(
            _error!,
            style: AppTextStyles.caption.copyWith(color: AppColors.danger),
          ),
        ],
        if (running) ...[
          const SizedBox(height: 12),
          Text(
            'Register the bridge with your agent:',
            style: AppTextStyles.caption,
          ),
          const SizedBox(height: 6),
          _CommandBox(
            text:
                'claude mcp add chess-prep -- node '
                '<repo>/tools/mcp/chess_prep_mcp.mjs',
          ),
          const SizedBox(height: 10),
          Text(
            'The shim finds this app automatically through:',
            style: AppTextStyles.caption,
          ),
          const SizedBox(height: 4),
          SelectableText(
            _endpointPath ?? '',
            style: AppTextStyles.caption.copyWith(fontFamily: 'monospace'),
          ),
          const SizedBox(height: 10),
          Text(
            'That file holds the access token. Turning this off deletes it '
            'and invalidates the token.',
            style: AppTextStyles.caption.copyWith(
              color: AppColors.onSurfaceDim,
            ),
          ),
        ],
      ],
    );
  }
}

class _CommandBox extends StatelessWidget {
  final String text;

  const _CommandBox({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: AppColors.divider),
      ),
      child: Row(
        children: [
          Expanded(
            child: SelectableText(
              text,
              style: AppTextStyles.caption.copyWith(fontFamily: 'monospace'),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.copy, size: 16),
            tooltip: 'Copy command',
            onPressed: () {
              unawaited(Clipboard.setData(ClipboardData(text: text)));
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('Command copied.')));
            },
          ),
        ],
      ),
    );
  }
}
