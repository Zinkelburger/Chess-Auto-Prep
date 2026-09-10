import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../../models/repertoire_metadata.dart';
import '../../../models/study_document.dart';
import '../../../services/storage/storage_factory.dart';
import '../../../theme/app_text_styles.dart';
import '../models/person_record.dart';
import '../services/opponent_store.dart';

/// An inline browser: link a whole study or one chapter without a modal.
class PlayerStudyLinks extends StatefulWidget {
  const PlayerStudyLinks({
    super.key,
    required this.personId,
    required this.store,
  });
  final String personId;
  final OpponentStore store;
  @override
  State<PlayerStudyLinks> createState() => _PlayerStudyLinksState();
}

class _PlayerStudyLinksState extends State<PlayerStudyLinks> {
  List<RepertoireMetadata> _studies = [];
  List<String> _chapters = [];
  String? _selected;
  String _query = '';
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final studies = await StorageFactory.instance.listStudyFiles();
      if (mounted) {
        setState(() {
          _studies = studies;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  Future<void> _select(String path) async {
    if (!mounted) return;
    setState(() {
      _selected = path;
      _chapters = [];
      _error = null;
    });
    try {
      final text = await StorageFactory.instance.readFile(path);
      if (text == null) throw StateError('File is missing');
      final names = StudyDocument.fromPgn(
        text,
        name: p.basenameWithoutExtension(path),
      ).chapters.map((c) => c.name).toList();
      if (mounted && _selected == path) setState(() => _chapters = names);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _link(String path, [String? chapter]) async {
    try {
      final person = widget.store.person(widget.personId);
      if (person == null) return;
      if (person.studyLinks.any(
        (l) => l.path == path && l.chapter == chapter,
      )) {
        return;
      }
      await widget.store.savePerson(
        person.copyWith(
          studyLinks: [
            ...person.studyLinks,
            PlayerStudyLink(path: path, chapter: chapter),
          ],
        ),
      );
      if (mounted) setState(() => _error = null);
    } catch (e) {
      if (mounted) setState(() => _error = 'Not saved: $e');
    }
  }

  Future<void> _browse() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['pgn'],
    );
    if (file?.path == null || !mounted) return;
    await _select(file!.path!);
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('Link a study or chapter', style: AppTextStyles.body),
            const SizedBox(width: 16),
            SizedBox(
              width: 260,
              child: TextField(
                decoration: const InputDecoration(
                  hintText: 'Search studies',
                  isDense: true,
                ),
                onChanged: (value) {
                  if (mounted) setState(() => _query = value);
                },
              ),
            ),
            TextButton(
              onPressed: _browse,
              child: const Text('Browse PGN files'),
            ),
          ],
        ),
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (_loading) const LinearProgressIndicator(),
        SizedBox(
          height: 190,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _studies.isEmpty
                    ? const Text(
                        'No studies yet. Use New study in the player row, or browse a PGN file.',
                      )
                    : ListView(
                        children: [
                          for (final study in _studies.where(
                            (s) => s.name.toLowerCase().contains(
                              _query.toLowerCase(),
                            ),
                          ))
                            ListTile(
                              dense: true,
                              title: Text(study.name),
                              selected: _selected == study.filePath,
                              onTap: () => _select(study.filePath),
                              trailing: TextButton(
                                onPressed: () => _link(study.filePath),
                                child: const Text('Link study'),
                              ),
                            ),
                        ],
                      ),
              ),
              const VerticalDivider(),
              Expanded(
                child: _selected == null
                    ? const Text('Select a study to see its chapters.')
                    : ListView(
                        children: [
                          ListTile(
                            dense: true,
                            title: Text(p.basename(_selected!)),
                            trailing: TextButton(
                              onPressed: () => _link(_selected!),
                              child: const Text('Link file'),
                            ),
                          ),
                          for (final chapter in _chapters)
                            ListTile(
                              dense: true,
                              title: Text(chapter),
                              trailing: TextButton(
                                onPressed: () => _link(_selected!, chapter),
                                child: const Text('Link chapter'),
                              ),
                            ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
