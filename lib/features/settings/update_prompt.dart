import 'dart:async';

import 'package:flutter/material.dart';

import '../../ui/listening_state.dart';
import 'app_updates.dart';
import 'update_offer.dart';

/// Puts the "is available" question over the app when a check the app made
/// by itself finds a new version: Install (or Download, for a copy updated
/// by hand), Later, or Skip this version. Each offer is asked once.
class UpdatePrompt extends StatefulWidget {
  const UpdatePrompt({
    super.key,
    required this.updates,
    required this.navigator,
    required this.child,
  });

  final AppUpdates updates;

  /// The dialog is raised over the app's navigator, which sits below this.
  final GlobalKey<NavigatorState> navigator;
  final Widget child;

  @override
  State<UpdatePrompt> createState() => _UpdatePromptState();
}

enum _Answer { accept, later, skip }

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
    final answer = await showDialog<_Answer>(
      context: context,
      builder: (context) => _UpdateDialog(offer: offer, updates: updates),
    );
    if (!mounted) return;
    switch (answer) {
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

class _UpdateDialog extends StatelessWidget {
  const _UpdateDialog({required this.offer, required this.updates});

  final UpdateOffer offer;
  final AppUpdates updates;

  @override
  Widget build(BuildContext context) {
    void answer(_Answer a) => Navigator.of(context).pop(a);
    return AlertDialog(
      title: Text('Chess Auto Prep ${offer.version} is available'),
      content: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              offer.installable
                  ? 'It installs when you close the app.'
                  : 'Download the new version from GitHub.',
            ),
          ),
          TextButton(
            onPressed: () => unawaited(updates.openPage(offer)),
            child: const Text('Release notes'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => answer(_Answer.skip),
          child: const Text('Skip this version'),
        ),
        TextButton(
          onPressed: () => answer(_Answer.later),
          child: const Text('Later'),
        ),
        FilledButton(
          autofocus: true,
          onPressed: () => answer(_Answer.accept),
          child: Text(offer.installable ? 'Install' : 'Download'),
        ),
      ],
    );
  }
}
