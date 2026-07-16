part of 'unified_engine_pane.dart';

mixin _EnginePaneTable on _UnifiedEnginePaneStateBase {
  // ─── Unified Move Table ─────────────────────────────────────────────────

  Widget _buildUnifiedMoveTable() {
    return ListenableBuilder(
      listenable: Listenable.merge([
        _settings,
        _analysis.discoveryResult,
        _analysis.results,
        _analysis.poolStatus,
        _probabilityService.currentPosition,
      ]),
      builder: (context, _) {
        final moves = _mergeMoves();

        return Stack(
          key: _previewStackKey,
          clipBehavior: Clip.none,
          children: [
            ListView(
              padding: const EdgeInsets.only(top: 4, bottom: 4),
              children: [
                _buildTableHeader(),
                const Divider(height: 1),
                if (moves.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 1.5),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Analyzing...',
                          style: TextStyle(
                            color: Colors.grey[500],
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  ...moves.map(_buildMoveRow),
              ],
            ),
            if (widget.boardPreview != null)
              FloatingBoardPreview(
                stackKey: _previewStackKey,
                controller: widget.boardPreview!,
                flipped: !widget.isWhiteRepertoire,
                ownerTag: _previewStackKey,
              ),
          ],
        );
      },
    );
  }

  static const _colHeaderTip =
      'Tap to dim this column; tap again to restore full color.';

  Widget _buildColumnHeader({
    required String columnId,
    required String label,
    required TextAlign textAlign,
    double? width,
    Widget? leading,
    String? tooltipExtra,
  }) {
    final muted = _settings.isAnalysisColumnMuted(columnId);
    final style = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      color: muted ? AppColors.onSurfaceDim : Colors.grey[400],
      letterSpacing: 0.5,
      decoration: muted ? TextDecoration.lineThrough : null,
      decorationColor: AppColors.onSurfaceDim,
    );

    final child = Row(
      mainAxisAlignment: textAlign == TextAlign.right
          ? MainAxisAlignment.end
          : MainAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (leading != null) ...[leading, const SizedBox(width: 2)],
        Text(
          label,
          style: style,
          textAlign: textAlign,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );

    final header = Tooltip(
      message: tooltipExtra != null
          ? '$tooltipExtra\n$_colHeaderTip'
          : _colHeaderTip,
      child: Material(
        color: muted
            ? Colors.white.withValues(alpha: 0.04)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(4),
        child: InkWell(
          onTap: () {
            final id = columnId;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _settings.toggleAnalysisColumnMuted(id);
            });
          },
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
            child: child,
          ),
        ),
      ),
    );

    if (width != null) {
      return SizedBox(width: width, child: header);
    }
    return Expanded(child: header);
  }

  static const _narrowTableWidth = 200;

  Widget _buildTableHeader() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < _narrowTableWidth;
        final showMaia =
            !narrow && _settings.showMaia && _settings.fetchMaiaForOpponent;
        final moveWidth = narrow ? 36.0 : 52.0;
        final evalWidth = narrow ? 44.0 : 58.0;
        final hPad = narrow ? 4.0 : 12.0;

        return Padding(
          padding: EdgeInsets.symmetric(horizontal: hPad, vertical: 6),
          child: Row(
            children: [
              SizedBox(
                width: moveWidth,
                child: Text(
                  'MOVE',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey[500],
                    letterSpacing: 0.5,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              _buildColumnHeader(
                columnId: EngineSettings.colEval,
                label: 'EVAL',
                textAlign: TextAlign.center,
                width: evalWidth,
                tooltipExtra: 'Stockfish evaluation',
              ),
              if (!narrow) const SizedBox(width: 8),
              _buildColumnHeader(
                columnId: EngineSettings.colLine,
                label: 'LINE',
                textAlign: TextAlign.left,
                tooltipExtra: 'Principal variation continuation',
              ),
              if (showMaia)
                _buildColumnHeader(
                  columnId: EngineSettings.colMaia,
                  label: 'MAIA',
                  textAlign: TextAlign.right,
                  width: 46,
                  tooltipExtra: 'Maia ${_settings.maiaElo} prediction',
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildMoveRow(MergedMove move) {
    return EngineMoveRow(
      move: move,
      settings: _settings,
      fen: widget.fen,
      boardPreview: widget.boardPreview,
      onMoveSelected: widget.onMoveSelected,
      onLineMoveTapped: widget.onLineMoveTapped,
      previewStackKey: _previewStackKey,
    );
  }

  // ─── Merge Logic ──────────────────────────────────

  List<MergedMove> _mergeMoves() {
    final byUci = <String, MergedMove>{};
    final discovery = _analysis.discoveryResult.value;

    if (_selectedMoveUcis.isEmpty) {
      for (final line in discovery.lines) {
        if (line.pv.isEmpty) continue;
        final uci = line.pv.first;
        final m = byUci.putIfAbsent(uci, () => MergedMove(uci: uci));
        m.stockfishCp = line.scoreCp;
        m.stockfishMate = line.scoreMate;
        m.fullPv = line.pv;
        m.stockfishRank = line.pvNumber;
      }
    } else {
      for (final uci in _selectedMoveUcis) {
        byUci[uci] = MergedMove(uci: uci);
      }
      for (final line in discovery.lines) {
        if (line.pv.isEmpty) continue;
        final m = byUci[line.pv.first];
        if (m != null) {
          m.stockfishCp = line.scoreCp;
          m.stockfishMate = line.scoreMate;
          m.fullPv = line.pv;
          m.stockfishRank = line.pvNumber;
        }
      }
    }

    final poolResults = _analysis.results.value;
    final dbData = _probabilityService.currentPosition.value;

    for (final m in byUci.values) {
      final poolResult = poolResults[m.uci];
      if (poolResult != null) {
        if (poolResult.hasEval) {
          m.stockfishCp = poolResult.scoreCp;
          m.stockfishMate = poolResult.scoreMate;
          if (poolResult.pv.isNotEmpty) m.fullPv = poolResult.pv;
        }
      }

      if (m.maiaProb == null && _maiaProbs != null) {
        m.maiaProb = _maiaProbs![m.uci] ?? 0.0;
      }

      if (m.dbProb == null && dbData != null) {
        double? found;
        for (final dbm in dbData.moves) {
          if (dbm.uci == m.uci) {
            found = dbm.playRate;
            if (m.san.isEmpty) m.san = dbm.san;
            break;
          }
        }
        m.dbProb = found ?? 0.0;
      }

      if (m.san.isEmpty) {
        m.san = uciToSan(widget.fen, m.uci);
      }
    }

    final sfMoves = byUci.values.where((m) => m.stockfishRank != null).toList()
      ..sort((a, b) => a.stockfishRank!.compareTo(b.stockfishRank!));
    final sfUcis = sfMoves.map((m) => m.uci).toSet();

    final others = byUci.values.where((m) => !sfUcis.contains(m.uci)).toList()
      ..sort((a, b) {
        if (a.hasStockfish && b.hasStockfish) {
          return b.effectiveCp.compareTo(a.effectiveCp);
        }
        if (a.hasStockfish) return -1;
        if (b.hasStockfish) return 1;
        final aMaia = a.maiaProb ?? 0.0;
        final bMaia = b.maiaProb ?? 0.0;
        if (aMaia != bMaia) return bMaia.compareTo(aMaia);
        return (b.dbProb ?? 0.0).compareTo(a.dbProb ?? 0.0);
      });

    return [...sfMoves, ...others];
  }
}
