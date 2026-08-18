/// Config dialog for engine weakness analysis.
///
/// Returns an [EngineWeaknessConfig] when the user taps "Start", or null
/// if cancelled.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/analysis_player_info.dart';
import '../models/engine_settings.dart';
import '../theme/app_colors.dart';
import 'info_hint.dart';
import 'labeled_toggle.dart';

/// Settings returned by the config dialog.
class EngineWeaknessConfig {
  final int depth;
  final int minGames;
  final int whiteCp;
  final int blackCp;
  final int workers;
  final bool redownload;
  final int monthsBack;

  const EngineWeaknessConfig({
    required this.depth,
    required this.minGames,
    required this.whiteCp,
    required this.blackCp,
    required this.workers,
    this.redownload = false,
    this.monthsBack = 6,
  });
}

/// Depth that actually gets used: deep enough to be trusted for opening
/// positions, shallow enough that a few hundred of them finish in minutes.
const int _kDefaultDepth = 15;

class EngineWeaknessConfigDialog extends StatefulWidget {
  final AnalysisPlayerInfo? playerInfo;

  /// True when the player already has engine evals, i.e. this run replaces
  /// them. Only changes the wording of the header.
  final bool isReanalysis;

  const EngineWeaknessConfigDialog({
    super.key,
    this.playerInfo,
    this.isReanalysis = false,
  });

  @override
  State<EngineWeaknessConfigDialog> createState() =>
      _EngineWeaknessConfigDialogState();
}

class _EngineWeaknessConfigDialogState
    extends State<EngineWeaknessConfigDialog> {
  late final TextEditingController _depthCtrl;
  late final TextEditingController _minGamesCtrl;
  late final TextEditingController _whiteCpCtrl;
  late final TextEditingController _blackCpCtrl;
  late final TextEditingController _workersCtrl;
  late final TextEditingController _monthsCtrl;

  /// Freshness is what people almost always want when they re-run this, so
  /// the fetch is opted *out* of, not into — but only where there is a source
  /// to fetch from. PGN-file imports have none, and leaving it on there
  /// would abort the run in [_redownloadGames].
  late bool _redownload = _canRedownload;

  bool get _canRedownload => widget.playerInfo?.canRedownload ?? false;

  @override
  void initState() {
    super.initState();
    final settings = EngineSettings.instance;
    _depthCtrl = TextEditingController(text: '$_kDefaultDepth');
    _minGamesCtrl = TextEditingController(text: '3');
    _whiteCpCtrl = TextEditingController(text: '-50');
    _blackCpCtrl = TextEditingController(text: '100');
    _workersCtrl = TextEditingController(text: '${settings.workers}');
    _monthsCtrl = TextEditingController(
      text: '${widget.playerInfo?.monthsBack ?? 6}',
    );
  }

  @override
  void dispose() {
    _depthCtrl.dispose();
    _minGamesCtrl.dispose();
    _whiteCpCtrl.dispose();
    _blackCpCtrl.dispose();
    _workersCtrl.dispose();
    _monthsCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    Navigator.of(context).pop(
      EngineWeaknessConfig(
        depth: int.tryParse(_depthCtrl.text) ?? _kDefaultDepth,
        minGames: int.tryParse(_minGamesCtrl.text) ?? 3,
        whiteCp: int.tryParse(_whiteCpCtrl.text) ?? -50,
        blackCp: int.tryParse(_blackCpCtrl.text) ?? 100,
        workers:
            int.tryParse(_workersCtrl.text) ?? EngineSettings.instance.workers,
        redownload: _redownload,
        monthsBack: int.tryParse(_monthsCtrl.text) ?? 6,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: SizedBox(
        width: 520,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(context),
              const Divider(height: 24),
              Wrap(
                spacing: 16,
                runSpacing: 12,
                children: [
                  _field(
                    'Depth',
                    _depthCtrl,
                    80,
                    hint:
                        'How deep Stockfish searches every position.\n'
                        'Each extra ply costs roughly double the time, so $_kDefaultDepth '
                        'keeps a\nfew hundred positions to minutes. Raise it to '
                        '20+ only for a\nfinal pass over a short list.',
                  ),
                  _field(
                    'Min games',
                    _minGamesCtrl,
                    80,
                    hint:
                        'Skip positions you have reached fewer times than this.\n'
                        'Raising it keeps the run on lines you actually play '
                        'instead of\none-off transpositions.',
                  ),
                  _field(
                    'CP score (white)',
                    _whiteCpCtrl,
                    120,
                    hint:
                        'Flags a position as bad for White when the evaluation is\n'
                        'at or below this, in centipawns (100 = one pawn).\n'
                        'Negative means White already stands worse, so -50 marks\n'
                        '"half a pawn down or worse". Only affects which positions\n'
                        'are highlighted — every position is still evaluated.',
                  ),
                  _field(
                    'CP score (black)',
                    _blackCpCtrl,
                    120,
                    hint:
                        'Flags a position as bad for Black when the evaluation is\n'
                        'at or above this, in centipawns (100 = one pawn).\n'
                        'Evaluations are always from White\'s side, so a positive\n'
                        'number means Black stands worse: 100 marks "a pawn down\n'
                        'or worse". Only affects highlighting, not what is evaluated.',
                  ),
                  _field(
                    'Workers',
                    _workersCtrl,
                    80,
                    hint:
                        'How many Stockfish processes evaluate positions in parallel.\n'
                        'More finishes sooner but leaves less CPU for the rest of\n'
                        'the machine. The default follows your engine settings.',
                  ),
                ],
              ),
              if (_canRedownload) ...[
                const Divider(height: 24),
                Row(
                  children: [
                    AppCheckbox(
                      label:
                          'Re-download from '
                          '${widget.playerInfo!.platformDisplayName}',
                      value: _redownload,
                      onChanged: (v) => setState(() => _redownload = v),
                    ),
                    const SizedBox(width: 6),
                    InfoHint(
                      'Fetches this player\'s latest games from '
                      '${widget.playerInfo!.platformDisplayName} and rebuilds\n'
                      'the opening trees before the engine runs, so games played\n'
                      'since the last download are included. Leave it off to\n'
                      'analyze the games already on disk.',
                    ),
                    const SizedBox(width: 12),
                    // Kept mounted and merely disabled when the box is off, so
                    // ticking it doesn't shuffle the row.
                    _field(
                      'Months',
                      _monthsCtrl,
                      64,
                      enabled: _redownload,
                      hint:
                          'How far back to fetch, in months. Larger ranges take\n'
                          'longer to download and analyze. Used only when '
                          're-downloading.',
                    ),
                  ],
                ),
                if (widget.playerInfo!.downloadedAt != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 48, top: 4),
                    child: Text(
                      'Last downloaded ${widget.playerInfo!.downloadTimeAgo}'
                      ' · fetched ${widget.playerInfo!.rangeDescription}',
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.onSurfaceMuted,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
              ],
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _submit,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Start'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    // On a re-run the title says what the button said — "Re-analyze" — and the
    // explanation drops to the subtitle, rather than repeating the first-run
    // title back at someone who has already done this once.
    final title = widget.isReanalysis ? 'Re-analyze' : 'Analyze with Engine';
    final subtitle = widget.isReanalysis
        ? 'Analyze with Engine · re-evaluate your most-played positions '
              'with Stockfish'
        : 'Evaluate your most-played positions with Stockfish';

    return Row(
      children: [
        const Icon(Icons.refresh, size: 28),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                subtitle,
                style: const TextStyle(
                  color: AppColors.onSurfaceSoft,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _field(
    String label,
    TextEditingController ctrl,
    double width, {
    bool enabled = true,
    required String hint,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: enabled ? null : AppColors.onSurfaceMuted,
              ),
            ),
            const SizedBox(width: 4),
            InfoHint(hint, size: 14),
          ],
        ),
        const SizedBox(height: 4),
        SizedBox(
          width: width,
          child: TextField(
            controller: ctrl,
            enabled: enabled,
            style: const TextStyle(fontSize: 13),
            keyboardType: const TextInputType.numberWithOptions(signed: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[\d-]')),
            ],
            decoration: const InputDecoration(
              isDense: true,
              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              border: OutlineInputBorder(),
            ),
          ),
        ),
      ],
    );
  }
}
