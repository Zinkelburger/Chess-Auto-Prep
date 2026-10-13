import 'package:flutter/material.dart';
import '../../storage/chapter_files.dart';
import '../../ui/theme.dart';
import 'studies.dart';
import 'study_import_source.dart';

Future<StudyResult?> showStudyImport(
  BuildContext context,
  Studies studies, {
  bool append = false,
}) => showDialog<StudyResult>(
  context: context,
  builder: (_) => _Import(studies: studies, into: studies.open, append: append),
);

enum _Source { file, pgn, url }

class _Import extends StatefulWidget {
  const _Import({
    required this.studies,
    required this.into,
    required this.append,
  });
  final Studies studies;
  final ChapterRef? into;
  final bool append;
  @override
  State<_Import> createState() => _ImportState();
}

class _ImportState extends State<_Import> {
  final _input = TextEditingController();
  final _name = TextEditingController();
  var _source = _Source.file;
  bool _append = false;
  @override
  void initState() {
    super.initState();
    _append = widget.append && widget.into != null;
  }

  StudyImportData? _data;
  String? _problem;
  bool _busy = false;
  @override
  void dispose() {
    _input.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _read() async {
    setState(() {
      _busy = true;
      _problem = null;
      _data = null;
    });
    try {
      final source = widget.studies.imports;
      final result = await switch (_source) {
        _Source.file => source.file(),
        _Source.pgn => source.pgn(_input.text),
        _Source.url => source.url(_input.text),
      };
      if (!mounted) return;
      setState(() {
        if (result is StudyImportData) {
          _data = result;
        }
        if (result is StudyImportProblem) _problem = result.message;
      });
    } catch (_) {
      if (mounted)
        setState(
          () =>
              _problem = 'Could not read this source. Check it and try again.',
        );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      final result = await widget.studies.importPreview(
        _data!,
        into: _append ? widget.into : null,
        name: _append || _name.text.trim().isEmpty ? null : _name.text.trim(),
      );
      if (!mounted) return;
      if (result is StudyProblem) {
        setState(() => _problem = result.sentence);
      } else {
        Navigator.pop(context, result);
      }
    } catch (_) {
      if (mounted)
        setState(
          () => _problem =
              'Could not finish importing. Your preview is still available.',
        );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: const Text('Import chapters'),
      content: SizedBox(
        width: nameDialogWidth * 2,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SegmentedButton<_Source>(
                showSelectedIcon: false,
                selected: {_source},
                segments: const [
                  ButtonSegment(value: _Source.file, label: Text('PGN file')),
                  ButtonSegment(value: _Source.pgn, label: Text('Paste PGN')),
                  ButtonSegment(value: _Source.url, label: Text('Lichess URL')),
                ],
                onSelectionChanged: _busy
                    ? null
                    : (value) => setState(() {
                        _source = value.single;
                        _input.clear();
                        _data = null;
                        _problem = null;
                      }),
              ),
              const SizedBox(height: Space.m),
              if (_source != _Source.file)
                TextField(
                  controller: _input,
                  enabled: !_busy,
                  minLines: _source == _Source.pgn ? 4 : 1,
                  maxLines: _source == _Source.pgn ? 8 : 2,
                  decoration: InputDecoration(
                    labelText: _source == _Source.pgn
                        ? 'PGN'
                        : 'Study or chapter URL',
                  ),
                  onChanged: (_) => setState(() {
                    _data = null;
                    _problem = null;
                  }),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton(
                  onPressed: _busy ? null : _read,
                  child: Text(
                    _source == _Source.file
                        ? 'Choose PGN file…'
                        : 'Preview chapters',
                  ),
                ),
              ),
              if (_busy) const LinearProgressIndicator(),
              if (_data case final data?) ...[
                const SizedBox(height: Space.m),
                Text('${data.chapter.lines.length} chapters · ${data.name}'),
                if (!data.complete)
                  const Text(
                    'Some games are incomplete. A new study preserves their original text.',
                  ),
                const SizedBox(height: Space.m),
                if (widget.into != null)
                  SegmentedButton<bool>(
                    showSelectedIcon: false,
                    selected: {_append},
                    segments: const [
                      ButtonSegment(value: false, label: Text('New study')),
                      ButtonSegment(value: true, label: Text('Current study')),
                    ],
                    onSelectionChanged: _busy
                        ? null
                        : (value) => setState(() => _append = value.single),
                  ),
                if (_append)
                  Text('Add to ${widget.into!.name}')
                else
                  TextField(
                    controller: _name,
                    enabled: !_busy,
                    decoration: const InputDecoration(
                      labelText: 'Study name (optional)',
                    ),
                  ),
              ],
              if (_problem != null)
                Padding(
                  padding: const EdgeInsets.only(top: Space.m),
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      _problem!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy || _data == null || (_append && !_data!.complete)
              ? null
              : _import,
          child: Text(_append ? 'Add chapters' : 'Import study'),
        ),
      ],
    ),
  );
}
