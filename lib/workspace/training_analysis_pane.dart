import 'package:flutter/material.dart';

import '../ui/theme.dart';
import 'engine_pane.dart';
import 'workspace.dart';

/// The shared engine controls as a resizable tab alongside training.
class TrainingAnalysisPane extends StatefulWidget {
  const TrainingAnalysisPane({super.key, required this.workspace, this.onMove});
  final Workspace workspace;
  final ValueChanged<String>? onMove;

  @override
  State<TrainingAnalysisPane> createState() => _TrainingAnalysisPaneState();
}

class _TrainingAnalysisPaneState extends State<TrainingAnalysisPane> {
  final _settings = ValueNotifier(false);

  @override
  void dispose() {
    _settings.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.all(Space.m),
    child: EnginePane(
      session: widget.workspace.session,
      analysis: widget.workspace.analysis,
      settings: widget.workspace.settings,
      settingsOpen: _settings,
      coresAvailable: widget.workspace.coresAvailable,
      onMove: widget.onMove,
    ),
  );
}
