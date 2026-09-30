import 'dart:async';

import 'package:flutter/material.dart';

import '../chess/audit/chapter_audit.dart';
import '../chess/fen.dart';
import '../ui/theme.dart';
import 'chapter_audit.dart';
import 'document_session.dart';

/// The Audit tab: the chapter's own moves checked against the engine.
///
/// A button starts the audit (Stop while it runs) and one quiet line says
/// how far it got. Under it, one row per finding, mistakes first: a
/// move of ours that loses, or a good reply of theirs the chapter never
/// answers. Clicking a row puts the board on the position before that
/// move, where the fix is played like any move; the × puts the finding
/// aside for this chapter.
class AuditPane extends StatefulWidget {
  const AuditPane({super.key, required this.audit, required this.session});

  final ChapterAudit audit;

  /// Followed so a finding the user has since fixed drops out at once.
  final DocumentSession session;

  @override
  State<AuditPane> createState() => _AuditPaneState();
}

class _AuditPaneState extends State<AuditPane> {
  /// Why the last press did nothing; cleared by the next.
  String? _problem;

  Future<void> _start() async {
    final problem = await widget.audit.start();
    if (!mounted) return;
    setState(() => _problem = problem);
  }

  @override
  Widget build(BuildContext context) {
    final audit = widget.audit;
    return ListenableBuilder(
      listenable: Listenable.merge([audit, widget.session]),
      builder: (context, _) {
        final findings = audit.findings;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _controls(context),
            _status(context, findings.length),
            const Divider(height: 1),
            Expanded(child: _list(context, findings)),
            if (audit.dismissalsNotKept) _notKept(context),
            if (audit.dismissedCount > 0) _dismissedRow(context),
          ],
        );
      },
    );
  }

  Widget _controls(BuildContext context) {
    final audit = widget.audit;
    final running = audit.state is AuditRunning;
    final stopping = switch (audit.state) {
      AuditRunning(:final stopping) => stopping,
      _ => false,
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.m, Space.m, Space.m, Space.s),
      child: Wrap(
        spacing: Space.s,
        runSpacing: Space.s,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (running)
            FilledButton.icon(
              onPressed: stopping ? null : audit.stop,
              icon: const Icon(Icons.pause),
              label: const Text('Stop'),
            )
          else
            Tooltip(
              message: 'Check the chapter\'s moves and the replies it misses',
              child: FilledButton.icon(
                onPressed: audit.canStart ? () => unawaited(_start()) : null,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Audit'),
              ),
            ),
          Tooltip(
            message: 'Also ask ChessDB for good replies (sends positions)',
            child: FilterChip(
              label: const Text('ChessDB'),
              selected: audit.askChessDb,
              onSelected: running
                  ? null
                  : (on) {
                      if (!mounted) return;
                      setState(() => audit.askChessDb = on);
                    },
            ),
          ),
        ],
      ),
    );
  }

  Widget _status(BuildContext context, int shown) {
    final theme = Theme.of(context);
    final found = shown == 1 ? '1 finding' : '$shown findings';
    final (words, error) = switch (widget.audit.state) {
      _ when _problem != null => (_problem!, true),
      AuditIdle() => ('', false),
      AuditRunning(:final checked, :final of, :final stopping) => (
        '${stopping ? 'Stopping' : 'Checking'} · $checked of $of positions'
            ' · $found',
        false,
      ),
      AuditDone(complete: true, :final of) => (
        'Checked $of positions · $found',
        false,
      ),
      AuditDone(:final checked, :final of, :final chessDbDropped) => (
        [
          checked < of
              ? 'Stopped at $checked of $of positions'
              : 'Checked $of positions',
          found,
          if (chessDbDropped) 'ChessDB stopped answering',
          'Audit again to finish',
        ].join(' · '),
        false,
      ),
      AuditFailed(:final reason) => (reason, true),
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.m, 0, Space.m, Space.s),
      child: Text(
        words,
        style: theme.textTheme.bodySmall?.copyWith(
          color: error ? theme.colorScheme.error : null,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  Widget _list(BuildContext context, List<AuditFinding> findings) {
    if (findings.isEmpty) {
      final words = switch (widget.audit.state) {
        AuditIdle() =>
          'Audit checks your moves and the good replies '
              'the chapter misses.',
        AuditRunning() => '',
        AuditDone() => 'Nothing found.',
        AuditFailed() => '',
      };
      return Padding(
        padding: const EdgeInsets.all(Space.m),
        child: Text(words, style: Theme.of(context).textTheme.bodySmall),
      );
    }
    return ListView.builder(
      itemCount: findings.length,
      itemExtent: trainRowHeight,
      itemBuilder: (context, index) {
        final finding = findings[index];
        return _FindingRow(
          key: ValueKey(finding.key),
          finding: finding,
          onOpen: () => widget.audit.goTo(finding),
          onDismiss: () => widget.audit.dismiss(finding),
        );
      },
    );
  }

  Widget _notKept(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.m, Space.s, Space.m, 0),
      child: Text(
        'Dismissals could not be saved; they last only until you audit '
        'again.',
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.error,
        ),
      ),
    );
  }

  Widget _dismissedRow(BuildContext context) {
    final count = widget.audit.dismissedCount;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.m),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '$count dismissed',
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
          TextButton(
            onPressed: widget.audit.restoreDismissed,
            child: const Text('Restore'),
          ),
        ],
      ),
    );
  }
}

/// One finding: the move, what kind, and the numbers that make it one.
class _FindingRow extends StatelessWidget {
  const _FindingRow({
    super.key,
    required this.finding,
    required this.onOpen,
    required this.onDismiss,
  });

  final AuditFinding finding;
  final VoidCallback onOpen;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return InkWell(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.only(left: Space.m, right: Space.xs),
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: auditMoveText(finding),
                          style: monoText.copyWith(color: scheme.onSurface),
                        ),
                        TextSpan(text: '  ${auditKind(finding)}'),
                      ],
                    ),
                    style: theme.textTheme.bodyMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    auditNumbers(finding),
                    style: theme.textTheme.labelSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: IconSize.action),
              tooltip: 'Dismiss',
              visualDensity: VisualDensity.compact,
              onPressed: onDismiss,
            ),
          ],
        ),
      ),
    );
  }
}

String auditKind(AuditFinding finding) => switch (finding) {
  WeakMove(:final mistake) => mistake ? 'Mistake' : 'Inaccuracy',
  StrongReply() => 'Strong reply',
};

/// The move, numbered, a weak move of ours marked `?` (`?!` for an
/// inaccuracy): `12.Nf3?`, `9…Nd4`.
String auditMoveText(AuditFinding finding) {
  final mark = switch (finding) {
    WeakMove(:final mistake) => mistake ? '?' : '?!',
    StrongReply() => '',
  };
  final (number, black) = _moveNumber(finding.fen);
  return '$number${black ? '…' : '.'}${finding.san}$mark';
}

/// What is at stake and how often it comes up. A mate is said as one,
/// never as pawns.
String auditNumbers(AuditFinding finding) {
  final reach = finding.reach;
  return [
    ...switch (finding) {
      WeakMove(:final missesMate, :final allowsMate, :final lossCp) => [
        missesMate
            ? 'misses mate'
            : allowsMate
            ? 'allows mate'
            : 'loses ${_pawns(lossCp!)}',
        'best ${finding.bestSan}',
      ],
      StrongReply(:final mates, :final behindCp, :final share) => [
        finding.fromChessDb ? 'ChessDB' : 'Engine',
        mates
            ? 'mates'
            : behindCp == 0
            ? 'their best'
            : '${_pawns(behindCp!)} below their best',
        if (share != null) 'Maia ${(share * 100).round()}%',
        'no answer',
      ],
    },
    if (reach != null) _reach(reach),
  ].join(' · ');
}

String _pawns(int cp) => (cp / 100).toStringAsFixed(1);

String _reach(double reach) {
  if (reach >= 0.995) return 'always';
  final onceIn = reach <= 0 ? 0 : (1 / reach).round();
  return onceIn < 1 || onceIn > 9999 ? 'rarely' : '1 in $onceIn';
}

/// The number of the move played from [fen], and whether it is Black's.
(int, bool) _moveNumber(Fen fen) {
  final fields = fen.value.split(' ');
  final black = fields.length > 1 && fields[1] == 'b';
  final number = fields.length > 5 ? int.tryParse(fields[5]) ?? 1 : 1;
  return (number, black);
}
