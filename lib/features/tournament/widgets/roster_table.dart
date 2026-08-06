/// The entry list, with resolution status per entrant.
library;

import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import '../models/opponent_probability.dart';
import '../models/player_identity.dart';
import '../models/roster_entry.dart';

class RosterTable extends StatelessWidget {
  final Roster roster;
  final SimulationResult simulation;
  final String? selectedId;
  final ValueChanged<RosterEntry>? onSelect;

  const RosterTable({
    super.key,
    required this.roster,
    required this.simulation,
    this.selectedId,
    this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    if (roster.entries.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No entry list loaded.\n\n'
            'Paste one on the right, or import it from an agent through the '
            'MCP bridge.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    final probs = {for (final o in simulation.opponents) o.playerId: o};

    // Most likely opponents first once a simulation exists; otherwise by
    // rating, which is the order the entry list itself implies.
    final sorted = [...roster.entries]
      ..sort((a, b) {
        final pa = probs[a.id]?.probAny ?? -1;
        final pb = probs[b.id]?.probAny ?? -1;
        if (pa != pb) return pb.compareTo(pa);
        return b.seedRating.compareTo(a.seedRating);
      });

    return ListView.builder(
      itemCount: sorted.length,
      itemBuilder: (context, i) {
        final entry = sorted[i];
        return _RosterRow(
          entry: entry,
          probability: probs[entry.id],
          selected: entry.id == selectedId,
          onTap: onSelect == null ? null : () => onSelect!(entry),
        );
      },
    );
  }
}

class _RosterRow extends StatelessWidget {
  final RosterEntry entry;
  final OpponentProbability? probability;
  final bool selected;
  final VoidCallback? onTap;

  const _RosterRow({
    required this.entry,
    required this.probability,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final identity = entry.identity;

    return Material(
      color: selected ? AppColors.surfaceHighlight : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              SizedBox(width: 52, child: _probabilityLabel(context)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (entry.isMe)
                          const Padding(
                            padding: EdgeInsets.only(right: 6),
                            child: Icon(Icons.person, size: 14),
                          ),
                        if ((entry.title ?? identity?.title) != null)
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: Text(
                              entry.title ?? identity!.title!,
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: AppColors.expectimax,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        Flexible(
                          child: Text(
                            entry.name,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              decoration: entry.withdrawn
                                  ? TextDecoration.lineThrough
                                  : null,
                              color: entry.withdrawn
                                  ? AppColors.onSurfaceDim
                                  : AppColors.ink,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    _identityLine(context),
                  ],
                ),
              ),
              SizedBox(
                width: 48,
                child: Text(
                  entry.rating?.toString() ?? '—',
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    color: AppColors.onSurfaceMuted,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _probabilityLabel(BuildContext context) {
    if (entry.isMe) {
      return Text(
        'you',
        style: TextStyle(color: AppColors.onSurfaceDim, fontSize: 11),
      );
    }
    final p = probability?.probAny;
    if (p == null) return const SizedBox.shrink();

    return Text(
      '${(p * 100).toStringAsFixed(0)}%',
      style: TextStyle(
        fontSize: 13,
        fontWeight: p >= 0.5 ? FontWeight.bold : FontWeight.normal,
        color: p >= 0.5
            ? AppColors.ink
            : p >= 0.15
            ? AppColors.onSurfaceMuted
            : AppColors.onSurfaceDim,
      ),
    );
  }

  Widget _identityLine(BuildContext context) {
    final identity = entry.identity;

    if (identity == null || !identity.hasAccount) {
      final ambiguous = identity?.alternates.isNotEmpty ?? false;
      return Text(
        ambiguous
            ? '${identity!.alternates.length} possible accounts — needs a choice'
            : 'no account resolved',
        style: TextStyle(
          fontSize: 11,
          color: ambiguous ? AppColors.warning : AppColors.onSurfaceDim,
        ),
      );
    }

    final actionable = identity.isActionable;
    return Row(
      children: [
        Icon(
          actionable ? Icons.check_circle_outline : Icons.help_outline,
          size: 11,
          color: actionable ? AppColors.success : AppColors.warning,
        ),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            '${identity.chesscomUsername ?? identity.lichessUsername} · '
            '${identity.source.label}'
            '${actionable ? '' : ' (unconfirmed)'}',
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              color: actionable ? AppColors.onSurfaceMuted : AppColors.warning,
            ),
          ),
        ),
      ],
    );
  }
}
