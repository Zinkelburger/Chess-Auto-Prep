import 'dart:async';

import 'package:flutter/material.dart';

import '../../chess/pgn/chapter.dart';
import '../../ui/listening_state.dart';
import '../../ui/theme.dart';
import 'study_sender.dart';

/// Asks where on Lichess the open study goes, sends it, and says what
/// Lichess now holds. One question: a new study, or one already there.
Future<void> showSendToLichess(
  BuildContext context, {
  required StudySender sender,
  required Chapter study,
  required String name,
  Future<bool> Function(BuildContext)? onLogIn,
}) async {
  sender.reset();
  await showDialog<void>(
    context: context,
    builder: (_) =>
        _Send(sender: sender, study: study, name: name, onLogIn: onLogIn),
  );
}

class _Send extends StatefulWidget {
  const _Send({
    required this.sender,
    required this.study,
    required this.name,
    this.onLogIn,
  });

  final StudySender sender;
  final Chapter study;
  final String name;
  final Future<bool> Function(BuildContext)? onLogIn;

  @override
  State<_Send> createState() => _SendState();
}

class _SendState extends State<_Send> with ListeningState<_Send> {
  late final _link = TextEditingController(
    text: switch (widget.sender.linkedStudy(widget.study)) {
      final study? => StudySender.studyPage(study).toString(),
      null => '',
    },
  );

  /// Into a study already on Lichess rather than a new one: by default
  /// the one the chapters came from or went to before.
  bool _existing = false;

  @override
  void initState() {
    super.initState();
    _existing = _link.text.isNotEmpty;
  }

  @override
  Listenable listenableOf(_Send widget) => widget.sender;

  @override
  void changed() {
    if (!mounted) return;
    // A new study made before the send stopped is where the next try goes,
    // so the chapters already there are not sent twice.
    if (widget.sender.state case SendFailed(:final study?) when !_existing) {
      _existing = true;
      _link.text = StudySender.studyPage(study).toString();
    }
    setState(() {});
  }

  @override
  void dispose() {
    _link.dispose();
    super.dispose();
  }

  int get _count => widget.study.lines.length;

  String? get _target => StudySender.studyIn(_link.text);

  bool get _ready => !_existing || _target != null;

  void _send() =>
      unawaited(widget.sender.send(into: _existing ? _target : null));

  Future<void> _logIn() async {
    final logIn = widget.onLogIn;
    if (logIn == null) return;
    if (await logIn(context) && mounted) _send();
  }

  /// Where the chapters go: a new study, or the one the link names.
  List<Widget> _destination(ThemeData theme, {required bool locked}) => [
    SegmentedButton<bool>(
      showSelectedIcon: false,
      selected: {_existing},
      segments: const [
        ButtonSegment(value: false, label: Text('New study')),
        ButtonSegment(value: true, label: Text('Existing study')),
      ],
      onSelectionChanged: locked
          ? null
          : (value) => setState(() => _existing = value.single),
    ),
    const SizedBox(height: Space.m),
    if (_existing) ...[
      TextField(
        controller: _link,
        enabled: !locked,
        decoration: InputDecoration(
          labelText: 'Lichess study link',
          errorText: _link.text.trim().isEmpty || _target != null
              ? null
              : 'Use a link to a Lichess study.',
        ),
        onChanged: (_) => setState(() {}),
      ),
      const SizedBox(height: Space.s),
      Text(
        'Chapters sent there before are updated in place; the others are '
        'added.',
        style: theme.textTheme.bodySmall,
      ),
    ] else
      Text(
        'Makes a private study on your Lichess account.',
        style: theme.textTheme.bodySmall,
      ),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = widget.sender.state;
    final sending = state is Sending;
    final done = state is SendDone;
    return PopScope(
      canPop: !sending,
      child: AlertDialog(
        title: const Text('Send to Lichess'),
        content: SizedBox(
          width: nameDialogWidth * 1.5,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '$_count ${_count == 1 ? 'chapter' : 'chapters'} of '
                '“${widget.name}”',
              ),
              const SizedBox(height: Space.m),
              ..._destination(theme, locked: sending || done),
              const SizedBox(height: Space.m),
              _Outcome(
                state: state,
                onOpen: (study) => unawaited(
                  widget.sender.openPage(StudySender.studyPage(study)),
                ),
                onLogIn: widget.onLogIn == null ? null : _logIn,
              ),
            ],
          ),
        ),
        actions: [
          if (!done)
            TextButton(
              onPressed: sending ? null : () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
          if (done)
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Done'),
            )
          else
            FilledButton(
              onPressed: sending || !_ready ? null : _send,
              child: Text(
                state is SendFailed
                    ? 'Send again'
                    : 'Send $_count ${_count == 1 ? 'chapter' : 'chapters'}',
              ),
            ),
        ],
      ),
    );
  }
}

/// What the send is doing or came to, in the dialog's last lines.
class _Outcome extends StatelessWidget {
  const _Outcome({required this.state, required this.onOpen, this.onLogIn});

  final StudySend state;
  final ValueChanged<String> onOpen;
  final VoidCallback? onLogIn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      liveRegion: true,
      child: switch (state) {
        SendIdle() => const SizedBox.shrink(),
        Sending(:final done, :final total) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LinearProgressIndicator(value: total == 0 ? null : done / total),
            const SizedBox(height: Space.s),
            Text('Sending chapter ${done + 1} of $total…'),
          ],
        ),
        SendDone(:final study, :final added, :final updated, :final skipped) =>
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                [
                  'Sent to lichess.org/study/$study',
                  if (added > 0) '$added added',
                  if (updated > 0) '$updated updated',
                ].join(' · '),
              ),
              if (skipped > 0)
                Text(
                  '$skipped ${skipped == 1 ? 'chapter was' : 'chapters were'} '
                  'not read whole and stayed here.',
                  style: theme.textTheme.bodySmall,
                ),
              const SizedBox(height: Space.s),
              Text(
                'Lichess keeps moves, comments, glyphs and arrows, not engine '
                'evaluations: its graph comes from Request a computer '
                'analysis there.',
                style: theme.textTheme.bodySmall,
              ),
              TextButton(
                onPressed: () => onOpen(study),
                child: const Text('Open on Lichess'),
              ),
            ],
          ),
        SendFailed(:final sentence, :final login) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(sentence, style: TextStyle(color: theme.colorScheme.error)),
            if (login && onLogIn != null)
              TextButton(
                onPressed: onLogIn,
                child: const Text('Log in to Lichess'),
              ),
          ],
        ),
      },
    );
  }
}
