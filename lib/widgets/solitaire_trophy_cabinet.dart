import 'dart:async';

import 'package:flutter/material.dart';

import '../models/solitaire_trophy.dart';
import '../services/solitaire_trophy_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../utils/pgn_date_utils.dart';

/// Dialog that shows the user's collection of solitaire trophies.
class SolitaireTrophyCabinet extends StatefulWidget {
  /// Open the trophy's game in the viewer, parked on the position it was
  /// won in. Without it a trophy is a dead end — the game and the FEN are
  /// stored with every one, and there was no way back to them.
  final void Function(SolitaireTrophy trophy)? onOpenGame;

  const SolitaireTrophyCabinet({super.key, this.onOpenGame});

  @override
  State<SolitaireTrophyCabinet> createState() => _SolitaireTrophyCabinetState();
}

class _SolitaireTrophyCabinetState extends State<SolitaireTrophyCabinet> {
  List<SolitaireTrophy> _trophies = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final trophies = await SolitaireTrophyService.instance.loadAll();
    if (!mounted) return;
    setState(() {
      _trophies = List.of(trophies);
      _loading = false;
    });
  }

  Future<void> _deleteTrophy(String id) async {
    await SolitaireTrophyService.instance.deleteById(id);
    if (!mounted) return;
    setState(() {
      _trophies.removeWhere((t) => t.id == id);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 600),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 0),
              child: Row(
                children: [
                  const Icon(
                    Icons.emoji_events,
                    color: AppColors.starAccent,
                    size: 24,
                  ),
                  const SizedBox(width: 10),
                  const Text('Trophy cabinet', style: AppTextStyles.title),
                  const Spacer(),
                  if (_trophies.isNotEmpty)
                    Text(
                      '${_trophies.length} ${_trophies.length == 1 ? 'trophy' : 'trophies'}',
                      style: AppTextStyles.caption,
                    ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, size: 20),
                  ),
                ],
              ),
            ),
            const Divider(),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(32),
                child: CircularProgressIndicator(),
              )
            else if (_trophies.isEmpty)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.emoji_events_outlined,
                      size: 48,
                      color: AppColors.onSurfaceDim,
                    ),
                    SizedBox(height: 12),
                    Text(
                      'No trophies yet',
                      style: TextStyle(
                        color: AppColors.onSurfaceMuted,
                        fontSize: 14,
                      ),
                    ),
                    SizedBox(height: 8),
                    Text(
                      'Finish a game in solitaire, then press "Analyse for '
                      'trophies".\n'
                      'Every move you tried that the engine rates above the '
                      'move actually played earns one.',
                      textAlign: TextAlign.center,
                      style: AppTextStyles.caption,
                    ),
                  ],
                ),
              )
            else
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: _trophies.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (ctx, i) => _buildTrophyRow(_trophies[i]),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildTrophyRow(SolitaireTrophy trophy) {
    final white = trophy.headers['White'] ?? '?';
    final black = trophy.headers['Black'] ?? '?';
    final date = formatPgnDate(trophy.headers['Date']);
    final gameInfo = '$white vs $black${date.isNotEmpty ? ' ($date)' : ''}';
    final advStr = (trophy.advantageCp / 100).toStringAsFixed(1);
    final canOpen = widget.onOpenGame != null && trophy.pgn.trim().isNotEmpty;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Icon(
              Icons.emoji_events,
              color: AppColors.starAccent,
              size: 20,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // "GM played" was a lie for every collection that is not a
                // master file — your own games included. The game played it.
                RichText(
                  text: TextSpan(
                    style: AppTextStyles.body.copyWith(fontSize: 13),
                    children: [
                      const TextSpan(text: 'You played '),
                      TextSpan(
                        text: trophy.userMove,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontFamily: AppTextStyles.monoFamily,
                        ),
                      ),
                      const TextSpan(text: '; the game went '),
                      TextSpan(
                        text: trophy.gmMove,
                        style: const TextStyle(
                          fontFamily: AppTextStyles.monoFamily,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '+$advStr better  ·  ${_formatCp(trophy.userEvalCp)} vs '
                  '${_formatCp(trophy.gmEvalCp)}',
                  style: AppTextStyles.monoDense.copyWith(
                    color: AppColors.onSurfaceSoft,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '$gameInfo · found ${_formatDate(trophy.date)}',
                  style: AppTextStyles.caption,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (canOpen)
            IconButton(
              onPressed: () {
                Navigator.of(context).pop();
                widget.onOpenGame!(trophy);
              },
              icon: const Icon(Icons.open_in_new, size: 18),
              tooltip: 'Open this game at the trophy position',
              visualDensity: VisualDensity.compact,
            ),
          IconButton(
            onPressed: () => unawaited(_deleteTrophy(trophy.id)),
            icon: const Icon(
              Icons.close,
              size: 18,
              color: AppColors.onSurfaceMuted,
            ),
            tooltip: 'Remove trophy',
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  String _formatCp(int cp) {
    final v = cp / 100.0;
    return v >= 0 ? '+${v.toStringAsFixed(1)}' : v.toStringAsFixed(1);
  }

  String _formatDate(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }
}
