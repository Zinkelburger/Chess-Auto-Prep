/// The network side of adding a player: fetch, save, report — behind one
/// progress dialog.
///
/// Carved out of `PlayerSelectionScreen`, which was a picker, three dialog
/// launchers and two download loops in one 800-line State. The screen now
/// decides *what* to add; this decides how the fetch is run and reported.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/analysis_player_info.dart';
import '../../services/analysis_games_service.dart';
import '../../utils/app_messages.dart';
import '../opponent_list_import_dialog.dart';

/// Runs downloads for the player picker.
class PlayerDownloadRunner {
  PlayerDownloadRunner(this._service);

  final AnalysisGamesService _service;

  /// Download and save one player's games, showing progress. Returns true
  /// when games were saved, so the caller knows whether to reload its list.
  Future<bool> downloadOne(
    BuildContext context,
    AnalysisPlayerInfo config,
  ) async {
    final progress = ValueNotifier<String>('Downloading games…');
    final close = _showProgress(
      context,
      progress,
      title: 'Downloading ${config.displayName}',
    );

    try {
      final pgns = await _service.downloadGamesFor(
        config,
        monthsBack: config.monthsBack,
        onProgress: (msg) => progress.value = msg,
      );

      if (pgns.trim().isEmpty) {
        close();
        if (context.mounted) {
          showAppSnackBar(
            context,
            AppMessages.noGamesFound(config.displayName),
          );
        }
        return false;
      }

      progress.value = 'Saving…';
      // Saves games and automatically clears stale cached analysis.
      await _service.saveAnalysisGames(
        pgns,
        platform: config.platform,
        username: config.username,
        maxGames: config.maxGames,
        monthsBack: config.monthsBack,
        accounts: config.accounts,
        group: config.group,
      );
      close();
      return true;
    } catch (e) {
      debugPrint('Download failed: $e');
      close();
      if (context.mounted) {
        showAppSnackBar(context, AppMessages.genericError, isError: true);
      }
      return false;
    } finally {
      progress.dispose();
    }
  }

  /// Download every opponent in a list, one after another, behind a single
  /// progress dialog. A failure on one person is recorded and the loop moves
  /// on — a field of twenty must not be abandoned because one account was
  /// renamed. Returns true if anything was saved.
  Future<bool> downloadList(
    BuildContext context,
    OpponentImportRequest request,
  ) async {
    final opponents = request.list.downloadable;
    final progress = ValueNotifier<String>('Starting…');
    var cancelled = false;

    final close = _showProgress(
      context,
      progress,
      title: request.list.event ?? 'Adding opponents',
      onStop: () {
        cancelled = true;
        progress.value = 'Stopping after the current opponent…';
      },
    );

    var imported = 0;
    var skipped = 0;
    final failed = <String>[];

    try {
      for (var i = 0; i < opponents.length; i++) {
        if (cancelled) break;
        final opponent = opponents[i];
        final info = opponent.toPlayerInfo(
          group: request.list.event,
          maxGames: 100,
          monthsBack: request.monthsBack,
        );
        final label = '${opponent.name} (${i + 1}/${opponents.length})';

        if (!request.redownloadExisting) {
          final existing = await _service.findExistingPlayer(
            info.platform,
            info.username,
          );
          if (existing != null) {
            skipped++;
            continue;
          }
        }

        try {
          progress.value = '$label\nDownloading…';
          final pgns = await _service.downloadGamesFor(
            info,
            monthsBack: request.monthsBack,
            onProgress: (m) => progress.value = '$label\n$m',
          );
          if (pgns.trim().isEmpty) {
            failed.add('${opponent.name}: no games found');
            continue;
          }
          await _service.saveAnalysisGames(
            pgns,
            platform: info.platform,
            username: info.username,
            maxGames: info.maxGames,
            monthsBack: info.monthsBack,
            accounts: info.accounts,
            group: info.group,
          );
          imported++;
        } catch (e) {
          debugPrint('Opponent import failed for ${opponent.name}: $e');
          failed.add('${opponent.name}: $e');
        }
      }
    } finally {
      progress.dispose();
      close();
    }

    final parts = <String>[
      'Added $imported player${imported == 1 ? '' : 's'}',
      if (skipped > 0) '$skipped already saved',
      if (failed.isNotEmpty) '${failed.length} failed',
      if (cancelled) 'stopped early',
    ];
    if (!context.mounted) return imported > 0;
    showAppSnackBar(context, parts.join(' · '), isError: failed.isNotEmpty);

    if (failed.isNotEmpty) {
      unawaited(
        showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Some opponents could not be added'),
            content: SizedBox(
              width: 420,
              child: SingleChildScrollView(
                child: Text(failed.map((f) => '• $f').join('\n')),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        ),
      );
    }
    return imported > 0;
  }

  /// Show a blocking progress dialog; returns the function that closes it.
  ///
  /// The closer is idempotent and takes the navigator from *inside* the
  /// dialog, so the success path and the `finally` can both call it and
  /// neither can pop the picker instead of the dialog.
  VoidCallback _showProgress(
    BuildContext context,
    ValueNotifier<String> progress, {
    required String title,
    VoidCallback? onStop,
  }) {
    NavigatorState? navigator;
    var closed = false;

    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) {
          navigator = Navigator.of(ctx);
          return PopScope(
            canPop: false,
            child: AlertDialog(
              title: Text(title),
              content: ValueListenableBuilder<String>(
                valueListenable: progress,
                builder: (_, message, _) => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 16),
                    Text(message, textAlign: TextAlign.center),
                  ],
                ),
              ),
              actions: [
                if (onStop != null)
                  TextButton(onPressed: onStop, child: const Text('Stop')),
              ],
            ),
          );
        },
      ),
    );

    return () {
      if (closed) return;
      closed = true;
      if (navigator?.mounted ?? false) navigator!.pop();
    };
  }
}
