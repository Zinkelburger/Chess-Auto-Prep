/// The "which time controls" question, asked the same way wherever games
/// are downloaded into Player analysis: the single-player dialog and the
/// tournament-field import. One widget, one remembered answer.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/analysis_player_info.dart';
import '../../services/games_library/game_filter.dart';
import '../labeled_toggle.dart';

/// Six checkboxes in two columns, fastest first, each captioned with its
/// time range. Bullet is off by default (see [defaultDownloadSpeeds]).
///
/// [error] paints nothing here; the host shows its own message, because
/// where that sentence goes differs per form. It exists so the host can
/// clear it the moment a box is ticked, through [onChanged].
class TimeControlPicker extends StatelessWidget {
  const TimeControlPicker({
    super.key,
    required this.speeds,
    required this.onChanged,
    this.title = 'Which time controls',
  });

  final Set<GameSpeed> speeds;

  /// Called with the new set after a toggle. Never called with the same set.
  final ValueChanged<Set<GameSpeed>> onChanged;

  /// The section heading; null hides it.
  final String? title;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (title != null) ...[
          Text(title!, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
        ],
        // Two columns: six rows of checkbox would push the action buttons
        // below the fold on a laptop.
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            for (final speed in selectableGameSpeeds)
              SizedBox(
                width: 196,
                child: AppCheckbox(
                  key: Key('download-speed-${speed.name}'),
                  label: speed.label,
                  subtitle: speed.rangeDescription,
                  value: speeds.contains(speed),
                  onChanged: (on) {
                    final next = {...speeds};
                    if (on) {
                      next.add(speed);
                    } else {
                      next.remove(speed);
                    }
                    onChanged(next);
                  },
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// The time controls the user last downloaded with, shared by every form
/// that asks. Someone who ticked Bullet for one opponent gets Bullet ticked
/// for the next, whichever way they add them.
class DownloadSpeedsMemory {
  DownloadSpeedsMemory._();

  static const _key = 'analysis_download.speeds';

  /// The remembered set, or null when nothing has been saved yet or the
  /// saved value was empty (an empty filter is never a valid answer).
  static Future<Set<GameSpeed>?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = gameSpeedsFromNames(prefs.getStringList(_key));
    return saved == null || saved.isEmpty ? null : saved;
  }

  static Future<void> save(Set<GameSpeed> speeds) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key, [
      for (final s in selectableGameSpeeds)
        if (speeds.contains(s)) s.name,
    ]);
  }

  /// Fire-and-forget [save], for a dialog popping on the same tick.
  static void remember(Set<GameSpeed> speeds) => unawaited(save(speeds));
}

/// [speeds] as the tail of a sentence: "blitz, rapid or classical", "any
/// time control", or "no time control" for an empty set.
String gameSpeedsPhrase(Set<GameSpeed> speeds) {
  if (speeds.isEmpty) return 'no time control';
  if (speeds.containsAll(selectableGameSpeeds)) return 'any time control';
  final names = [
    for (final s in selectableGameSpeeds)
      if (speeds.contains(s)) s.label.toLowerCase(),
  ];
  if (names.length == 1) return names.single;
  return '${names.sublist(0, names.length - 1).join(', ')} or ${names.last}';
}
