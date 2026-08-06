/// Import, simulate, and run prep. The workflow reads top to bottom.
library;

import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import '../models/roster_entry.dart';
import '../services/roster_import.dart';
import '../services/tournament_session.dart';

class TournamentControls extends StatefulWidget {
  final TournamentSession session;
  final RosterEntry? selected;

  const TournamentControls({super.key, required this.session, this.selected});

  @override
  State<TournamentControls> createState() => _TournamentControlsState();
}

class _TournamentControlsState extends State<TournamentControls> {
  final _pasteController = TextEditingController();
  final _eventController = TextEditingController();
  final _myIdController = TextEditingController();
  final _roundsController = TextEditingController(text: '5');

  bool _accelerated = false;
  List<String> _repertoires = const [];
  String? _whitePath;
  String? _blackPath;
  List<String> _importWarnings = const [];

  @override
  void initState() {
    super.initState();
    TournamentSession.availableRepertoires().then((paths) {
      if (mounted) setState(() => _repertoires = paths);
    });
  }

  @override
  void dispose() {
    _pasteController.dispose();
    _eventController.dispose();
    _myIdController.dispose();
    _roundsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _card(
          title: 'Entry list',
          children: [
            _field(
              controller: _eventController,
              label: 'Event name',
              hint: 'Spring Open',
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _field(
                    controller: _myIdController,
                    label: 'Your USCF ID',
                    hint: '12345678',
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 110,
                  child: _field(
                    controller: _roundsController,
                    label: 'Rounds',
                    hint: '5',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            CheckboxListTile(
              value: _accelerated,
              onChanged: (v) => setState(() => _accelerated = v ?? false),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('Accelerated pairings'),
              subtitle: Text(
                'Check only if the organizer announced it — never guessed.',
                style: TextStyle(fontSize: 11, color: AppColors.onSurfaceMuted),
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Paste the entry list',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _pasteController,
              maxLines: 6,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                isDense: true,
                hintText:
                    'CSV with a header row, or pasted text:\n'
                    '1  Smith, John   12345678  1850',
              ),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton(
                onPressed: _import,
                child: const Text('Import entry list'),
              ),
            ),
            if (_importWarnings.isNotEmpty) ...[
              const SizedBox(height: 10),
              ..._importWarnings.map(
                (w) => Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    '• $w',
                    style: TextStyle(fontSize: 11, color: AppColors.warning),
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 16),
        _card(
          title: 'Accounts',
          children: [
            Text(
              'Matches the field against the bundled USCF → chess.com '
              'directory. Run this before asking an agent to search — it is '
              'exact where it hits and costs nothing.',
              style: TextStyle(fontSize: 12, color: AppColors.onSurfaceMuted),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonal(
                onPressed: session.roster.entries.isEmpty
                    ? null
                    : () async {
                        final summary = session.resolveIdentities();
                        await session.save();
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              'Resolved ${summary.resolved} of '
                              '${summary.total} — ${summary.unresolved} need '
                              'a web search.',
                            ),
                          ),
                        );
                      },
                child: const Text('Resolve accounts'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _card(
          title: 'Likely opponents',
          children: [
            Text(
              'Simulates the whole event thousands of times rather than '
              'predicting one pairing sheet, so withdrawals, late entries and '
              'withholds are absorbed instead of breaking it.',
              style: TextStyle(fontSize: 12, color: AppColors.onSurfaceMuted),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonal(
                onPressed: session.roster.me == null
                    ? null
                    : () => session.simulate(),
                child: const Text('Simulate pairings'),
              ),
            ),
            if (session.simulation.trials > 0) ...[
              const SizedBox(height: 10),
              Text(
                '${session.simulation.trials} runs · expected score '
                '${session.simulation.expectedScore.toStringAsFixed(1)}'
                '/${session.simulation.rounds}'
                '${session.simulation.byeProb > 0.01 ? ' · ${(session.simulation.byeProb * 100).toStringAsFixed(0)}% chance of a bye' : ''}',
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ],
        ),
        const SizedBox(height: 16),
        _card(
          title: 'Prepare',
          children: [
            _repertoirePicker(
              label: 'White repertoire',
              value: _whitePath,
              onChanged: (v) => setState(() => _whitePath = v),
            ),
            const SizedBox(height: 10),
            _repertoirePicker(
              label: 'Black repertoire',
              value: _blackPath,
              onChanged: (v) => setState(() => _blackPath = v),
            ),
            const SizedBox(height: 12),
            if (session.isPreparing) ...[
              LinearProgressIndicator(value: session.progress?.fraction),
              const SizedBox(height: 8),
              Text(
                session.progress == null
                    ? 'Starting…'
                    : '${session.progress!.currentPlayer} '
                          '(${session.progress!.opponentsDone}/'
                          '${session.progress!.opponentsTotal}) '
                          '${session.progress!.detail}',
                style: TextStyle(fontSize: 11, color: AppColors.onSurfaceMuted),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton(
                  onPressed: session.cancelPrep,
                  child: const Text('Cancel'),
                ),
              ),
            ] else
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton(
                  onPressed:
                      (session.roster.me == null ||
                          (_whitePath == null && _blackPath == null))
                      ? null
                      : _runPrep,
                  child: const Text('Prepare tournament'),
                ),
              ),
            if (session.lastError != null) ...[
              const SizedBox(height: 8),
              Text(
                session.lastError!,
                style: TextStyle(fontSize: 11, color: AppColors.danger),
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _repertoirePicker({
    required String label,
    required String? value,
    required ValueChanged<String?> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        DropdownButtonFormField<String?>(
          initialValue: value,
          isExpanded: true,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            isDense: true,
          ),
          hint: Text(
            _repertoires.isEmpty ? 'No repertoires found' : 'None',
            style: const TextStyle(fontSize: 12),
          ),
          items: [
            const DropdownMenuItem<String?>(child: Text('None')),
            for (final path in _repertoires)
              DropdownMenuItem<String?>(
                value: path,
                child: Text(
                  path.split('/').last,
                  style: const TextStyle(fontSize: 12),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: onChanged,
        ),
      ],
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    required String hint,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Every field gets a visible title; a hint is not a label.
        Text(
          label,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        TextField(
          controller: controller,
          style: const TextStyle(fontSize: 13),
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            isDense: true,
            hintText: hint,
          ),
        ),
      ],
    );
  }

  Widget _card({required String title, required List<Widget> children}) {
    return Card(
      color: AppColors.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            ...children,
          ],
        ),
      ),
    );
  }

  Future<void> _import() async {
    final result = RosterImporter.parse(
      _pasteController.text,
      eventName: _eventController.text.trim(),
      rounds: int.tryParse(_roundsController.text.trim()) ?? 5,
      accelerated: _accelerated,
      myUscfId: _myIdController.text.trim(),
    );

    widget.session.setRoster(result.roster);
    await widget.session.save();
    if (!mounted) return;
    setState(() => _importWarnings = result.warnings);
  }

  Future<void> _runPrep() async {
    try {
      await widget.session.prepare(
        whiteRepertoirePath: _whitePath,
        blackRepertoirePath: _blackPath,
      );
    } catch (_) {
      // Surfaced through session.lastError in the build above.
    }
  }
}
