/// Chip descriptors for Edit context panels.
library;

import 'package:flutter/material.dart';

import 'repertoire_mode.dart';

typedef EditContextTabSpec = ({
  EditContextView view,
  String label,
  IconData icon,
});

const kEditContextTabs = <EditContextTabSpec>[
  (view: EditContextView.browse, label: 'Browse', icon: Icons.travel_explore),
  (view: EditContextView.engine, label: 'Engine', icon: Icons.bolt),
  (
    view: EditContextView.expectimax,
    label: 'Expectimax',
    icon: Icons.analytics,
  ),
  (view: EditContextView.lines, label: 'Lines', icon: Icons.library_books),
  (view: EditContextView.tree, label: 'Tree', icon: Icons.account_tree),
];
