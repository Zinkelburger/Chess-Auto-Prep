import 'package:flutter/material.dart';
import '../../storage/chapter_files.dart';
import '../../ui/theme.dart';
import 'studies.dart';
import 'studies_state.dart';
import 'study_import_source.dart';
import '../../ui/app_icons.dart';
import '../../ui/attempting.dart';
import '../../ui/form_dialog.dart';
import '../../ui/segments.dart';

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

class _ImportState extends State<_Import> with Attempting<_Import> {
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
  @override
  void dispose() {
    _input.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _read() async {
    setState(() => _data = null);
    final source = widget.studies.imports;
    final result = await attempt(
      'read study import source',
      () => switch (_source) {
        _Source.file => source.file(),
        _Source.pgn => source.pgn(_input.text),
        _Source.url => source.url(_input.text),
      },
      failure: 'Could not read this source. Check it and try again.',
    );
    if (result == null) return;
    setState(() {
      if (result is StudyImportData) _data = result;
      if (result is StudyImportProblem) problem = result.message;
    });
  }

  Future<void> _import() async {
    final data = _data!;
    final result = await attempt(
      'import study chapters',
      () => widget.studies.importPreview(
        data,
        into: _append ? widget.into : null,
        name: _append || _name.text.trim().isEmpty ? null : _name.text.trim(),
      ),
      failure: 'Could not finish importing. Your preview is still available.',
    );
    if (result == null || !mounted) return;
    if (result is StudyProblem) {
      setState(() => problem = result.sentence);
    } else {
      Navigator.pop(context, result);
    }
  }

  /// Where the chapters come from: a file, pasted PGN or a Lichess URL,
  /// and the button that reads them.
  List<Widget> _sourceFields() => [
    Segments<_Source>(
      segments: const [
        ButtonSegment(value: _Source.file, label: Text('PGN file')),
        ButtonSegment(value: _Source.pgn, label: Text('Paste PGN')),
        ButtonSegment(value: _Source.url, label: Text('Lichess URL')),
      ],
      selected: _source,
      onChanged: busy
          ? null
          : (value) => setState(() {
              _source = value;
              _input.clear();
              _data = null;
              problem = null;
            }),
    ),
    const SizedBox(height: Space.m),
    if (_source != _Source.file)
      TextField(
        controller: _input,
        enabled: !busy,
        minLines: _source == _Source.pgn ? 4 : 1,
        maxLines: _source == _Source.pgn ? 8 : 2,
        decoration: InputDecoration(
          labelText: _source == _Source.pgn ? 'PGN' : 'Study or chapter URL',
        ),
        onChanged: (_) => setState(() {
          _data = null;
          problem = null;
        }),
      ),
    Align(
      alignment: Alignment.centerLeft,
      child: _source == _Source.file
          ? OutlinedButton.icon(
              onPressed: busy ? null : _read,
              icon: const Icon(AppIcons.open, size: IconSize.action),
              label: const Text('Choose PGN file…'),
            )
          : OutlinedButton(
              onPressed: busy ? null : _read,
              child: const Text('Preview chapters'),
            ),
    ),
  ];

  /// What was read, and the study it goes into.
  List<Widget> _destination(StudyImportData data) => [
    const SizedBox(height: Space.m),
    Text('${data.chapter.lines.length} chapters · ${data.name}'),
    if (!data.complete)
      const Text(
        'Some games are incomplete. A new study preserves their original text.',
      ),
    const SizedBox(height: Space.m),
    if (widget.into != null)
      Segments<bool>(
        segments: const [
          ButtonSegment(value: false, label: Text('New study')),
          ButtonSegment(value: true, label: Text('Current study')),
        ],
        selected: _append,
        onChanged: busy ? null : (value) => setState(() => _append = value),
      ),
    if (_append)
      Text('Add to ${widget.into!.name}')
    else
      TextField(
        controller: _name,
        enabled: !busy,
        decoration: const InputDecoration(labelText: 'Study name (optional)'),
      ),
  ];

  @override
  Widget build(BuildContext context) => FormDialog(
    title: 'Import chapters',
    width: dialogWide,
    busy: busy,
    canFail: true,
    problem: problem,
    confirm: _append ? 'Add chapters' : 'Import study',
    onConfirm: _data == null || (_append && !_data!.complete) ? null : _import,
    body: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ..._sourceFields(),
          if (_data case final data?) ..._destination(data),
        ],
      ),
    ),
  );
}
