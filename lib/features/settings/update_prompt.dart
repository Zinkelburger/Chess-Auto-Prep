import 'dart:async';

import 'package:flutter/material.dart';

import '../../ui/listening_state.dart';
import '../../ui/theme.dart';
import 'app_updates.dart';
import 'update_offer.dart';
import 'update_rows.dart';

/// Puts the "is available" question over the app when a check the app made
/// by itself finds a new version: Update now, When I close the app (or
/// Download, for a copy updated by hand), or Skip this version. Each offer
/// is asked once.
///
/// Update now keeps the question up with the download's bar, then closes
/// the app through [closeApp]; the helper installs and opens it again.
class UpdatePrompt extends StatefulWidget {
  const UpdatePrompt({
    super.key,
    required this.updates,
    required this.navigator,
    required this.closeApp,
    required this.child,
  });

  final AppUpdates updates;

  /// The dialog is raised over the app's navigator, which sits below this.
  final GlobalKey<NavigatorState> navigator;

  /// Closes the app the way its window's close button does; false when the
  /// user kept it open.
  final Future<bool> Function() closeApp;
  final Widget child;

  @override
  State<UpdatePrompt> createState() => _UpdatePromptState();
}

enum _Answer { restart, accept, later, skip }

class _UpdatePromptState extends State<UpdatePrompt>
    with ListeningState<UpdatePrompt> {
  UpdateOffer? _asked;

  @override
  Listenable listenableOf(UpdatePrompt widget) => widget.updates;

  @override
  void changed() {
    final offer = widget.updates.prompt;
    if (offer == null || offer == _asked) return;
    _asked = offer;
    unawaited(_ask(offer));
  }

  Future<void> _ask(UpdateOffer offer) async {
    final context = widget.navigator.currentContext;
    if (context == null) return;
    final updates = widget.updates;
    final closeApp = widget.closeApp;
    final answer = await showDialog<_Answer>(
      context: context,
      builder: (context) => _UpdateDialog(offer: offer, updates: updates),
    );
    if (!mounted) return;
    switch (answer) {
      case _Answer.restart:
        updates.later();
        await updates.setReopen(true);
        // Kept open after all: a later close is for the day.
        if (!await closeApp()) await updates.setReopen(false);
      case _Answer.accept:
        await updates.accept(offer);
      case _Answer.skip:
        updates.skip(offer);
      case _Answer.later || null:
        updates.later();
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The question, and after Update now the download it started: its bar,
/// then the restart once the helper is armed.
class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog({required this.offer, required this.updates});

  final UpdateOffer offer;
  final AppUpdates updates;

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog>
    with ListeningState<_UpdateDialog> {
  /// Update now was pressed: the dialog follows the install from here.
  bool _updating = false;
  bool _answered = false;

  @override
  Listenable listenableOf(_UpdateDialog widget) => widget.updates;

  @override
  void changed() {
    if (_updating) _follow();
    if (mounted) setState(() {});
  }

  void _answer(_Answer answer) {
    if (_answered) return;
    _answered = true;
    stopListening();
    Navigator.of(context).pop(answer);
  }

  void _updateNow() {
    setState(() => _updating = true);
    unawaited(widget.updates.install());
    _follow();
  }

  /// Armed: restart. Cancelled, or the update went another way meanwhile:
  /// the question is over.
  void _follow() {
    switch (widget.updates.status) {
      case UpdateArmed():
        _answer(_Answer.restart);
      case UpdateDownloading() ||
          UpdateDownloaded() ||
          UpdateArming() ||
          UpdateFailed(offer: UpdateOffer()):
        break;
      case NotChecked() ||
          CheckingForUpdate() ||
          UpToDate() ||
          UpdateOffered() ||
          UpdateHelperStillRunning() ||
          UpdateFailed():
        _answer(_Answer.later);
    }
  }

  @override
  Widget build(BuildContext context) {
    final offer = widget.offer;
    return PopScope(
      canPop: !_updating,
      child: AlertDialog(
        title: Text(
          _updating
              ? 'Updating to Chess Auto Prep ${offer.version}'
              : 'Chess Auto Prep ${offer.version} is available',
        ),
        content: SizedBox(
          width: 440,
          child: _updating ? _progress(context) : _question(),
        ),
        actions: _updating ? _progressActions() : _questionActions(),
      ),
    );
  }

  Widget _question() => Row(
    children: [
      Expanded(
        child: Text(
          widget.offer.installable
              ? 'Update now closes the app and reopens it on the new version.'
              : 'Download the new version from GitHub.',
        ),
      ),
      TextButton(
        onPressed: () => unawaited(widget.updates.openPage(widget.offer)),
        child: const Text('Release notes'),
      ),
    ],
  );

  List<Widget> _questionActions() => [
    TextButton(
      onPressed: () => _answer(_Answer.skip),
      child: const Text('Skip this version'),
    ),
    if (widget.offer.installable) ...[
      TextButton(
        onPressed: () => _answer(_Answer.accept),
        child: const Text('When I close the app'),
      ),
      FilledButton(
        autofocus: true,
        onPressed: _updateNow,
        child: const Text('Update now'),
      ),
    ] else ...[
      TextButton(
        onPressed: () => _answer(_Answer.later),
        child: const Text('Later'),
      ),
      FilledButton(
        autofocus: true,
        onPressed: () => _answer(_Answer.accept),
        child: const Text('Download'),
      ),
    ],
  ];

  Widget _progress(BuildContext context) {
    final status = widget.updates.status;
    final failed = status is UpdateFailed;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LinearProgressIndicator(
          value: switch (status) {
            UpdateDownloading(:final fraction) => fraction,
            UpdateFailed() => 0,
            _ => null,
          },
        ),
        const SizedBox(height: Space.m),
        Text(
          switch (status) {
            UpdateDownloading(:final fraction) =>
              'Downloading… ${(fraction * 100).floor()}%',
            UpdateFailed(:final problem) => problemText(problem),
            _ => 'Starting the installer…',
          },
          style: failed
              ? TextStyle(color: Theme.of(context).colorScheme.error)
              : null,
        ),
      ],
    );
  }

  List<Widget> _progressActions() => switch (widget.updates.status) {
    UpdateFailed() => [
      TextButton(
        onPressed: () => _answer(_Answer.later),
        child: const Text('Close'),
      ),
      FilledButton(
        onPressed: () => unawaited(widget.updates.install()),
        child: const Text('Try again'),
      ),
    ],
    UpdateDownloading() => [
      TextButton(
        onPressed: widget.updates.cancelDownload,
        child: const Text('Cancel'),
      ),
    ],
    _ => const [TextButton(onPressed: null, child: Text('Cancel'))],
  };
}
