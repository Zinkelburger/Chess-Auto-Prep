import 'package:flutter/material.dart';

import '../models/solitaire_trophy.dart';
import '../services/solitaire_trophy_service.dart';
import '../theme/app_colors.dart';
import '../utils/pgn_date_utils.dart';

/// Dialog that shows the user's collection of solitaire trophies.
class SolitaireTrophyCabinet extends StatefulWidget {
  const SolitaireTrophyCabinet({super.key});

  @override
  State<SolitaireTrophyCabinet> createState() => _SolitaireTrophyCabinetState();
}

class _SolitaireTrophyCabinetState extends State<SolitaireTrophyCabinet> {
  List<SolitaireTrophy> _trophies = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
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
                  const Text(
                    'Trophy Cabinet',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  if (_trophies.isNotEmpty)
                    Text(
                      '${_trophies.length} ${_trophies.length == 1 ? 'trophy' : 'trophies'}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.onSurfaceMuted,
                      ),
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
              Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.emoji_events_outlined,
                      size: 48,
                      color: AppColors.onSurfaceDim,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'No trophies yet',
                      style: TextStyle(
                        color: AppColors.onSurfaceMuted,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Play solitaire mode, then analyze the game.\n'
                      'If your guess beats the GM\'s move, you earn a trophy!',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: AppColors.onSurfaceMuted,
                        fontSize: 12,
                      ),
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

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.emoji_events, color: AppColors.starAccent, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                RichText(
                  text: TextSpan(
                    style: const TextStyle(fontSize: 13),
                    children: [
                      const TextSpan(text: 'You played '),
                      TextSpan(
                        text: trophy.userMove,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontFamily: 'monospace',
                        ),
                      ),
                      const TextSpan(text: ', GM played '),
                      TextSpan(
                        text: trophy.gmMove,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '+$advStr advantage  |  ${_formatCp(trophy.userEvalCp)} vs ${_formatCp(trophy.gmEvalCp)}',
                  style: const TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    color: AppColors.onSurfaceSoft,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  gameInfo,
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.onSurfaceMuted,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  _formatDate(trophy.date),
                  style: const TextStyle(
                    fontSize: 10,
                    color: AppColors.onSurfaceMuted,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () => _deleteTrophy(trophy.id),
            icon: const Icon(
              Icons.close,
              size: 14,
              color: AppColors.onSurfaceMuted,
            ),
            tooltip: 'Remove trophy',
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(),
            padding: const EdgeInsets.all(4),
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
