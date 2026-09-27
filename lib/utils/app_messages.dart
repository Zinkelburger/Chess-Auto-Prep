import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'log.dart';
import 'network_errors.dart';

/// All user-facing notification strings in one place for easy auditing.
///
/// Messages are grouped by how they're displayed:
/// - **Errors**: shown as persistent SnackBars (user must dismiss)
/// - **Attention**: actionable notices shown as auto-dismissing SnackBars
/// - **Success**: routine completion messages stay quiet
/// - **Validation**: shown inline on form fields (not as SnackBars)
/// - **Inline**: shown in widget state areas (not as SnackBars)
class AppMessages {
  AppMessages._();

  // ── Errors (SnackBar, persistent until dismissed) ──────────────
  static const genericError = 'Something went wrong. Please try again.';
  static const createRepertoireFailed = 'Could not create repertoire.';
  static const deleteRepertoireFailed = 'Could not delete repertoire.';
  static const renameRepertoireFailed = 'Could not rename repertoire.';
  static const saveToRepertoireFailed = 'Could not save to repertoire.';
  static const importFailed = 'Import failed. Please try again.';
  static const loadPositionFailed = 'Could not load position.';
  static const clipboardReadFailed = 'Could not read clipboard.';
  static const clipboardWriteFailed = 'Could not copy to clipboard.';
  static const renameLineFailed = 'Could not rename line.';

  /// A download that never reached the server. Naming the site and the
  /// connection is the difference between "try again" and knowing that
  /// clicking again will not help until the network is back.
  static String downloadFailed(Object error, {required String site}) =>
      looksOffline(error)
      ? 'Could not reach $site. Check your internet connection and try again.'
      : 'Could not download from $site. Please try again.';

  /// What a list says while it is showing games the network could not be
  /// asked about. The games are real and already on this computer; the only
  /// thing missing is anything played since [lastFetched].
  static String showingSavedGames(String? lastFetched) => lastFetched == null
      ? 'Offline — showing the games saved on this computer.'
      : 'Offline — showing the games saved $lastFetched.';

  // ── Informational (SnackBar, auto-dismiss 3s) ─────────────────
  static String noGamesFound(String username) =>
      'No games found for $username.';
  static const clipboardEmpty = 'Clipboard is empty.';
  static const invalidFen = 'Invalid FEN string.';
  static const pgnCopied = 'PGN copied to clipboard.';
  static const fenCopied = 'FEN copied to clipboard.';
  static const movesCopied = 'Moves copied to clipboard.';
  static const linkCopied = 'Link copied to clipboard.';

  // ── Validation (inline on form fields, not SnackBars) ──────────
  static const enterUsername = 'Please enter a username';
  static const invalidGameCount = 'Enter a number of games (1 or more)';
  static const invalidMonths = 'Enter 1 or more';
  static const selectRepertoire = 'Select a repertoire first.';
  static String repertoireExists(String name) =>
      'A repertoire named "$name" already exists.';

  // ── Inline (shown in widget state, not SnackBars) ──────────────
  static const gamesAlreadyAnalyzed = 'Games were already analyzed.';
  static const noNewBlunders = 'No new blunders found.';
  static String addedTactics(int count) =>
      'Added $count new tactics position${count == 1 ? '' : 's'}.';
}

/// Show a styled SnackBar for errors or notices requiring attention.
/// Routine success notifications are intentionally silent across the app.
/// Set [requiresAttention] for a blocked action or other necessary guidance.
/// Use [isError] for persistent error notifications
/// that require the user to dismiss them. All snackbars carry a close icon so
/// they can be dismissed before the timeout; pass [actionLabel]/[onAction] for
/// an inline action (e.g. "Open", "Undo").
void showAppSnackBar(
  BuildContext context,
  String message, {
  bool isError = false,
  bool requiresAttention = false,
  String? actionLabel,
  VoidCallback? onAction,
  Duration? duration,
}) {
  if (!isError && !requiresAttention) return;
  // What the user was shown belongs in the log too: a report of "some red
  // message" is otherwise unanswerable, and the message names the action
  // that failed even when the cause was caught and handled.
  if (isError) {
    log.w(message, name: 'UI');
  }
  final screenWidth = MediaQuery.sizeOf(context).width;
  ScaffoldMessenger.of(context).clearSnackBars();
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        message,
        textAlign: actionLabel == null ? TextAlign.center : TextAlign.start,
      ),
      width: screenWidth < 500 ? screenWidth * 0.85 : 400,
      // Stated here rather than left to the theme: `width` is only legal on a
      // floating snackbar, and Flutter asserts rather than ignoring it. The
      // app's theme happens to set floating, so any surface built without
      // that theme — a widget test, a dialog rooted elsewhere — turned a
      // "Copied" message into a framework exception.
      behavior: SnackBarBehavior.floating,
      duration:
          duration ??
          (isError ? const Duration(days: 365) : const Duration(seconds: 3)),
      showCloseIcon: true,
      action: actionLabel != null && onAction != null
          ? SnackBarAction(label: actionLabel, onPressed: onAction)
          : null,
    ),
  );
}

/// Copy [text] quietly. [successMessage] is retained for existing callers.
/// Fire-and-forget so
/// button handlers stay synchronous.
void copyToClipboard(
  BuildContext context,
  String text, {
  String? successMessage,
}) {
  unawaited(Clipboard.setData(ClipboardData(text: text)));
}
