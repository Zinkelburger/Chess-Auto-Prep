/// Board-perspective selector for the PGN Viewer app bar.
///
/// Extracted from `pgn_viewer_screen.dart` (WS-C / B3). A popup menu letting
/// the user pick the default board orientation (a detected player, both
/// players, or always White/Black). State and the apply action come from the
/// shared [PgnViewerController].
library;

import 'package:flutter/material.dart';

import '../../core/pgn_viewer_controller.dart';

class PgnPerspectiveButton extends StatelessWidget {
  final PgnViewerController controller;

  const PgnPerspectiveButton({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final protagonist = controller.detectProtagonist();
    final bothPlayers = controller.detectBothPlayers();
    final isPlayerMode = controller.perspective.mode == PerspectiveMode.player;
    final isWhiteMode = controller.perspective.mode == PerspectiveMode.white;
    final isBlackMode = controller.perspective.mode == PerspectiveMode.black;

    final label = switch (controller.perspective.mode) {
      PerspectiveMode.white => 'White',
      PerspectiveMode.black => 'Black',
      PerspectiveMode.player => controller.perspective.playerName,
    };

    return PopupMenuButton<Perspective>(
      tooltip: 'Default view as',
      onSelected: controller.setPerspective,
      itemBuilder: (ctx) => [
        if (bothPlayers != null) ...[
          PopupMenuItem(
            value: Perspective(
                mode: PerspectiveMode.player, playerName: bothPlayers.player1),
            child: Row(children: [
              if (isPlayerMode &&
                  controller.perspective.playerName == bothPlayers.player1)
                const Icon(Icons.check, size: 16)
              else
                const SizedBox(width: 16),
              const SizedBox(width: 8),
              Text(bothPlayers.player1),
            ]),
          ),
          PopupMenuItem(
            value: Perspective(
                mode: PerspectiveMode.player, playerName: bothPlayers.player2),
            child: Row(children: [
              if (isPlayerMode &&
                  controller.perspective.playerName == bothPlayers.player2)
                const Icon(Icons.check, size: 16)
              else
                const SizedBox(width: 16),
              const SizedBox(width: 8),
              Text(bothPlayers.player2),
            ]),
          ),
        ] else if (protagonist != null)
          PopupMenuItem(
            value: Perspective(
                mode: PerspectiveMode.player, playerName: protagonist),
            child: Row(children: [
              if (isPlayerMode &&
                  controller.perspective.playerName == protagonist)
                const Icon(Icons.check, size: 16)
              else
                const SizedBox(width: 16),
              const SizedBox(width: 8),
              Text(protagonist),
            ]),
          ),
        PopupMenuItem(
          value: const Perspective(mode: PerspectiveMode.white),
          child: Row(children: [
            if (isWhiteMode)
              const Icon(Icons.check, size: 16)
            else
              const SizedBox(width: 16),
            const SizedBox(width: 8),
            const Text('Always White'),
          ]),
        ),
        PopupMenuItem(
          value: const Perspective(mode: PerspectiveMode.black),
          child: Row(children: [
            if (isBlackMode)
              const Icon(Icons.check, size: 16)
            else
              const SizedBox(width: 16),
            const SizedBox(width: 8),
            const Text('Always Black'),
          ]),
        ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Colors.grey[700]!),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 120),
          child: Text(
            label,
            style: const TextStyle(fontSize: 11),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }
}
