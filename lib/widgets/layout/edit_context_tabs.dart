/// Chip descriptors for Edit context panels.
library;

import 'package:flutter/material.dart';

import '../../models/repertoire_mode.dart';

typedef EditContextTabSpec = ({
  EditContextView view,
  String label,
  IconData icon,
  String tooltip,
});

/// Each panel carries a one-sentence description: the chips are two words
/// wide, which is not enough to tell "Engine" from "Expectimax" if you have
/// not read the docs.
const kEditContextTabs = <EditContextTabSpec>[
  (
    view: EditContextView.browse,
    label: 'Browse',
    icon: Icons.travel_explore,
    tooltip:
        'Opening explorer: what humans actually played from this position, '
        'with win rates.',
  ),
  (
    view: EditContextView.engine,
    label: 'Engine',
    icon: Icons.bolt,
    tooltip:
        'Stockfish: the objectively best moves here, with evaluations and '
        'their continuations.',
  ),
  (
    view: EditContextView.expectimax,
    label: 'Expectimax',
    icon: Icons.analytics,
    tooltip:
        'Best moves once likely human replies are weighed in — the practical '
        'choice rather than the objective one.',
  ),
  (
    view: EditContextView.lines,
    label: 'Lines',
    icon: Icons.library_books,
    tooltip: 'Every line in this chapter, searchable and filterable.',
  ),
  (
    view: EditContextView.tree,
    label: 'Tree',
    icon: Icons.account_tree,
    tooltip: 'The generated tree as a branching outline you can click through.',
  ),
];
