import 'package:flutter/material.dart';

/// All user-facing notification strings in one place for easy auditing.
///
/// Messages are grouped by how they're displayed:
/// - **Errors**: shown as persistent SnackBars (user must dismiss)
/// - **Informational**: shown as auto-dismissing SnackBars
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

  // ── Informational (SnackBar, auto-dismiss 3s) ─────────────────
  static String noGamesFound(String username) =>
      'No games found for $username.';
  static const clipboardEmpty = 'Clipboard is empty.';
  static const invalidFen = 'Invalid FEN string.';
  static const pgnCopied = 'PGN copied to clipboard.';
  static const fenCopied = 'FEN copied to clipboard.';
  static const linkCopied = 'Link copied to clipboard.';

  // ── Validation (inline on form fields, not SnackBars) ──────────
  static const enterUsername = 'Please enter a username';
  static const invalidGameCount = 'Enter a number between 1 and 500';
  static const invalidMonths = 'Enter 1 or more';
  static const selectRepertoire = 'Select a repertoire first.';
  static String repertoireExists(String name) =>
      'A repertoire named "$name" already exists.';

  // ── Inline (shown in widget state, not SnackBars) ──────────────
  static const noNewBlunders =
      'No new blunders found. Games may have already been analyzed.';
  static String addedTactics(int count) =>
      'Added $count new tactics position${count == 1 ? '' : 's'}.';
}

/// Show a styled SnackBar. Use [isError] for persistent error notifications
/// that require the user to dismiss them.
void showAppSnackBar(
  BuildContext context,
  String message, {
  bool isError = false,
}) {
  final screenWidth = MediaQuery.of(context).size.width;
  ScaffoldMessenger.of(context).clearSnackBars();
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        message,
        textAlign: TextAlign.center,
      ),
      width: screenWidth < 500 ? screenWidth * 0.85 : 400,
      duration: isError
          ? const Duration(days: 365)
          : const Duration(seconds: 3),
      backgroundColor: isError ? Colors.red[800] : null,
      showCloseIcon: isError,
      closeIconColor: Colors.white70,
    ),
  );
}
