import 'dart:async';

import 'package:flutter/material.dart';

import '../../../models/repertoire_metadata.dart';
import '../../../services/pgn_parsing_service.dart' as pgn;
import '../../../services/repertoire_creation.dart';
import '../../../services/storage/storage_factory.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../../../utils/app_messages.dart';
import '../../../widgets/common/searchable_picker_dialog.dart';
import '../../../widgets/pgn_import_dialog.dart';
import '../services/my_repertoire_settings.dart';

/// Designate which repertoire folders are the books you actually play as
/// White and as Black — the ones every game gets checked against.
///
/// Adding one is not only "pick from what is already here". A person who has
/// just installed the app, or who keeps their book as a PGN somewhere else,
/// had nothing to pick: the button answered with "No further repertoires to
/// add." and left them to find the Repertoire Builder, make one there, and
/// come back. So the same button also imports a `.pgn` from disk and starts an
/// empty repertoire, and either way designates what it made — the colour is
/// already known from the section you pressed Add in.
///
/// Body only, no surrounding card or title: it is shown both as a Settings
/// group and, via [showMyRepertoiresDialog], straight from the home pane. The
/// designation being two screens away from the games it explains was the
/// reason the deviation column read "—" for people who never found it.
class MyRepertoiresPanel extends StatefulWidget {
  const MyRepertoiresPanel({super.key});

  @override
  State<MyRepertoiresPanel> createState() => _MyRepertoiresPanelState();
}

/// Show [MyRepertoiresPanel] as its own dialog. Returns when it is dismissed;
/// changes are saved as they are made (the panel writes straight through to
/// [MyRepertoireSettings]), so there is no Apply.
Future<void> showMyRepertoiresDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('My repertoires'),
      content: const SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'The repertoires you actually play. Every game is compared '
                'against them to show where you left book.',
                style: TextStyle(fontSize: 12, color: AppColors.onSurfaceSoft),
              ),
              SizedBox(height: 12),
              MyRepertoiresPanel(),
            ],
          ),
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Done'),
        ),
      ],
    ),
  );
}

class _MyRepertoiresPanelState extends State<MyRepertoiresPanel> {
  final _settings = MyRepertoireSettings.instance;

  /// Designation (see [_mismatchKey]) → chapters whose `// Color:` header
  /// disagrees with the side the folder is designated for. A wrong-color
  /// book silently produces nonsense deviation reports, so surface it here.
  Map<String, List<String>> _colorMismatches = const {};

  static String _mismatchKey({required bool white, required String path}) =>
      '${white ? 'w' : 'b'}:$path';

  @override
  void initState() {
    super.initState();
    _settings.addListener(_onDesignationsChanged);
    unawaited(_settings.ensureLoaded().then((_) => _refreshColorCheck()));
  }

  @override
  void dispose() {
    _settings.removeListener(_onDesignationsChanged);
    super.dispose();
  }

  void _onDesignationsChanged() => _refreshColorCheck();

  Future<void> _refreshColorCheck() async {
    final results = <String, List<String>>{};
    for (final (white, paths) in [
      (true, _settings.whitePaths),
      (false, _settings.blackPaths),
    ]) {
      for (final folder in paths) {
        final wrong = <String>[];
        try {
          for (final chapter in await StorageFactory.instance.listChapters(
            folder,
          )) {
            final content = await StorageFactory.instance.readFile(
              chapter.filePath,
            );
            if (content == null) continue;
            final color = pgn.extractRepertoireColor(content);
            if (color != null && (color == 'white') != white) {
              wrong.add(chapter.name);
            }
          }
        } catch (_) {
          // Unreadable folders already surface as "no usable chapters".
        }
        if (wrong.isNotEmpty) {
          results[_mismatchKey(white: white, path: folder)] = wrong;
        }
      }
    }
    if (mounted) setState(() => _colorMismatches = results);
  }

  /// Add a book for one colour, from whichever of the three starting points
  /// the user actually has: one already in the app, a PGN on disk, or nothing
  /// at all yet.
  Future<void> _addRepertoire({required bool white}) async {
    final all = await StorageFactory.instance.listRepertoires();
    if (!mounted) return;
    final designated = _settings.pathsFor(white: white);
    final candidates = [
      for (final r in all)
        if (!designated.contains(r.filePath)) r,
    ];

    final source = await showDialog<_AddSource>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('Add ${white ? 'White' : 'Black'} repertoire'),
        children: [
          _SourceTile(
            icon: Icons.menu_book_outlined,
            title: 'Choose one I already have',
            subtitle: candidates.isEmpty
                ? all.isEmpty
                      ? 'You have no repertoires in the app yet'
                      : 'Every repertoire you have is already designated here'
                : '${candidates.length} available',
            enabled: candidates.isNotEmpty,
            onTap: () => Navigator.of(ctx).pop(_AddSource.existing),
          ),
          _SourceTile(
            icon: Icons.file_open_outlined,
            title: 'Import a PGN file…',
            subtitle: 'A study or repertoire exported from anywhere else',
            onTap: () => Navigator.of(ctx).pop(_AddSource.importFile),
          ),
          _SourceTile(
            icon: Icons.create_new_folder_outlined,
            title: 'Start an empty one…',
            subtitle: 'Name it now, add the lines in the Repertoire Builder',
            onTap: () => Navigator.of(ctx).pop(_AddSource.createEmpty),
          ),
        ],
      ),
    );
    if (source == null || !mounted) return;

    final taken = {for (final r in all) r.name.toLowerCase()};
    switch (source) {
      case _AddSource.existing:
        await _designateExisting(white: white, candidates: candidates);
      case _AddSource.importFile:
        await _importFromDisk(white: white, taken: taken);
      case _AddSource.createEmpty:
        await _createEmpty(white: white, taken: taken);
    }
  }

  Future<void> _designateExisting({
    required bool white,
    required List<RepertoireMetadata> candidates,
  }) async {
    final picked = await showSearchablePicker<RepertoireMetadata>(
      context: context,
      title: 'Add ${white ? 'White' : 'Black'} repertoire',
      searchHint: 'Search repertoires',
      items: [
        for (final r in candidates)
          PickerItem(value: r, label: r.name, icon: Icons.menu_book_outlined),
      ],
    );
    if (picked != null) {
      await _settings.addPath(white: white, path: picked.filePath);
    }
  }

  /// Import a `.pgn` and designate the repertoire it becomes. The file is
  /// copied into the app's own storage as a normal repertoire — designating a
  /// path outside it would break the moment the file moved.
  Future<void> _importFromDisk({
    required bool white,
    required Set<String> taken,
  }) async {
    final picked = await pickPgnImport();
    if (picked == null || !mounted) return;
    if (picked.error != null) {
      _say(picked.error!, isError: true);
      return;
    }
    final import = picked.result;
    if (import == null) return;

    final name = await _promptName(
      title: 'Name this repertoire',
      initial: picked.suggestedName ?? 'Imported repertoire',
      taken: taken,
    );
    if (name == null || !mounted) return;

    await _createAndDesignate(
      white: white,
      name: name,
      pgnContent: import.pgnContent,
      gameCount: import.gameCount,
      done:
          '$name added — ${import.gameCount} '
          '${import.gameCount == 1 ? 'line' : 'lines'} imported.',
    );
  }

  Future<void> _createEmpty({
    required bool white,
    required Set<String> taken,
  }) async {
    final name = await _promptName(
      title: 'Name the new repertoire',
      initial: '',
      taken: taken,
    );
    if (name == null || !mounted) return;

    await _createAndDesignate(
      white: white,
      name: name,
      done: '$name added. Build its lines in the Repertoire Builder.',
    );
  }

  Future<void> _createAndDesignate({
    required bool white,
    required String name,
    String? pgnContent,
    int gameCount = 0,
    required String done,
  }) async {
    try {
      final created = await createRepertoire(
        name: name,
        color: white ? 'White' : 'Black',
        pgnContent: pgnContent,
        gameCount: gameCount,
      );
      await _settings.addPath(white: white, path: created.directoryPath);
      _say(done);
    } catch (e) {
      debugPrint('Create repertoire failed: $e');
      _say(AppMessages.createRepertoireFailed, isError: true);
    }
  }

  /// Ask for a repertoire name, refusing empties and names already in use —
  /// in the field, so the answer arrives before the dialog closes.
  Future<String?> _promptName({
    required String title,
    required String initial,
    required Set<String> taken,
  }) {
    return showDialog<String>(
      context: context,
      builder: (ctx) =>
          _NameRepertoireDialog(title: title, initial: initial, taken: taken),
    );
  }

  void _say(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? AppColors.danger : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _settings,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _ColorDesignation(
            label: 'As White',
            paths: _settings.whitePaths,
            mismatchFor: (path) =>
                _colorMismatches[_mismatchKey(white: true, path: path)],
            onAdd: () => _addRepertoire(white: true),
            onRemove: (path) => _settings.removePath(white: true, path: path),
          ),
          const SizedBox(height: 12),
          _ColorDesignation(
            label: 'As Black',
            paths: _settings.blackPaths,
            mismatchFor: (path) =>
                _colorMismatches[_mismatchKey(white: false, path: path)],
            onAdd: () => _addRepertoire(white: false),
            onRemove: (path) => _settings.removePath(white: false, path: path),
          ),
        ],
      ),
    );
  }
}

/// Where a designated book can come from.
enum _AddSource { existing, importFile, createEmpty }

/// Name a repertoire about to be created. Its own widget so the controller
/// lives exactly as long as the dialog does — disposing one straight after
/// `showDialog` returns kills it while the close animation is still building
/// the field.
class _NameRepertoireDialog extends StatefulWidget {
  const _NameRepertoireDialog({
    required this.title,
    required this.initial,
    required this.taken,
  });

  final String title;
  final String initial;

  /// Existing repertoire names, lower-cased.
  final Set<String> taken;

  @override
  State<_NameRepertoireDialog> createState() => _NameRepertoireDialogState();
}

class _NameRepertoireDialogState extends State<_NameRepertoireDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _controller.text.trim();
    if (value.isEmpty) {
      setState(() => _error = 'Please enter a name');
      return;
    }
    if (widget.taken.contains(value.toLowerCase())) {
      setState(() => _error = 'A repertoire named "$value" already exists');
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 360,
        child: TextField(
          key: const Key('repertoire-name-field'),
          controller: _controller,
          autofocus: true,
          decoration: InputDecoration(
            labelText: 'Repertoire name',
            border: const OutlineInputBorder(),
            errorText: _error,
          ),
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
          onSubmitted: (_) => _submit(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Create')),
      ],
    );
  }
}

class _SourceTile extends StatelessWidget {
  const _SourceTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.enabled = true,
  });

  final IconData icon;
  final String title;

  /// Why this row is worth pressing — or, when it is not pressable, why not.
  final String subtitle;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      enabled: enabled,
      leading: Icon(icon, size: 20),
      title: Text(title, style: const TextStyle(fontSize: 14)),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
      onTap: enabled ? onTap : null,
    );
  }
}

class _ColorDesignation extends StatelessWidget {
  const _ColorDesignation({
    required this.label,
    required this.paths,
    required this.mismatchFor,
    required this.onAdd,
    required this.onRemove,
  });

  final String label;
  final List<String> paths;

  /// Chapter names in this folder marked for the *other* color, or null.
  final List<String>? Function(String path) mismatchFor;
  final VoidCallback onAdd;
  final ValueChanged<String> onRemove;

  static String _displayName(String path) => path.split(RegExp(r'[/\\]')).last;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: AppTextStyles.body.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            TextButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Add repertoire'),
            ),
          ],
        ),
        if (paths.isEmpty)
          Text(
            'None designated — deviations are not checked for this color.',
            style: AppTextStyles.caption.copyWith(
              color: AppColors.onSurfaceMuted,
            ),
          )
        else
          for (final path in paths) ...[
            Padding(
              padding: const EdgeInsets.only(left: 8, top: 2),
              child: Row(
                children: [
                  const Icon(
                    Icons.folder_open,
                    size: 16,
                    color: AppColors.onSurfaceMuted,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Tooltip(
                      message: path,
                      child: Text(
                        _displayName(path),
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.body.copyWith(fontSize: 13),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 16),
                    tooltip: 'Remove designation',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => onRemove(path),
                  ),
                ],
              ),
            ),
            if (mismatchFor(path) case final wrong?)
              Padding(
                padding: const EdgeInsets.only(left: 32, top: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.warning_amber,
                      size: 14,
                      color: AppColors.warning,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Marked for the other color: ${wrong.join(', ')} — '
                        'deviation reports from this folder may be nonsense.',
                        style: AppTextStyles.caption.copyWith(
                          color: AppColors.warning,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
      ],
    );
  }
}
