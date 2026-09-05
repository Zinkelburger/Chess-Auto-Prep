import 'dart:async';

import 'package:flutter/material.dart';

import '../../../models/repertoire_metadata.dart';
import '../../../services/pgn_parsing_service.dart' as pgn;
import '../../../services/repertoire_creation.dart';
import '../../../services/storage/storage_factory.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../../../utils/app_messages.dart';
import '../../../widgets/common/confirm_dialog.dart';
import '../../../widgets/pgn_import_dialog.dart';
import '../services/my_repertoire_settings.dart';

/// Designate which repertoire folders are the books you actually play as
/// White and as Black — the ones every game gets checked against.
///
/// Flat on purpose. Each colour has its books listed and, beside the heading,
/// the two ways to add one: **Import PGN…** goes straight to the system file
/// picker and designates what it imports, named after the file; **Add
/// existing** is a menu of the repertoires already in the app, with "New empty
/// repertoire…" at its foot for someone who wants to build the lines in the
/// Repertoire Builder first. It used to be a button that opened a chooser
/// dialog that opened the picker that opened a naming dialog — four screens
/// between "I have a PGN" and "it is my book" — and nobody got through it.
///
/// Body only, no surrounding card or title: it is shown both as a Settings
/// group and, via [showMyRepertoiresDialog], straight from the home pane. The
/// designation being two screens away from the games it explains was the
/// reason the deviation column read "—" for people who never found it.
class MyRepertoiresPanel extends StatefulWidget {
  const MyRepertoiresPanel({super.key, this.pickPgn = pickPgnImport});

  /// Opens the file picker and reads the chosen PGN. Injectable for tests;
  /// the default is the app's real picker.
  final Future<PickedPgnImport?> Function() pickPgn;

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
      title: const Text('My books'),
      content: const SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'The repertoires you actually play. Every game is compared '
                'against them to show where you left book.',
                style: AppTextStyles.caption,
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

  /// Every repertoire in the app, for the "Add existing" menus. Reloaded
  /// whenever the designations change, which is also whenever this panel
  /// creates one.
  List<RepertoireMetadata> _all = const [];

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
    unawaited(_settings.ensureLoaded().then((_) => _refresh()));
  }

  @override
  void dispose() {
    _settings.removeListener(_onDesignationsChanged);
    super.dispose();
  }

  void _onDesignationsChanged() => _refresh();

  Future<void> _refresh() async {
    List<RepertoireMetadata> all = const [];
    try {
      all = await StorageFactory.instance.listRepertoires();
    } catch (_) {
      // An unreadable repertoire root leaves the menu empty, not the panel
      // broken.
    }
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
    if (!mounted) return;
    setState(() {
      _all = all;
      _colorMismatches = results;
    });
  }

  Set<String> get _takenNames => {for (final r in _all) r.name.toLowerCase()};

  /// Repertoires in the app not yet designated for [white].
  List<RepertoireMetadata> _candidatesFor({required bool white}) {
    final designated = _settings.pathsFor(white: white);
    return [
      for (final r in _all)
        if (!designated.contains(r.filePath)) r,
    ];
  }

  /// Import a `.pgn` and designate the repertoire it becomes, in one step:
  /// the picker, then done. The repertoire takes the file's name (made
  /// unique if that name is in use) and the colour of the section the button
  /// sits in; both can be changed later in the Repertoire Builder.
  ///
  /// The file is copied into the app's own storage as a normal repertoire —
  /// designating a path outside it would break the moment the file moved.
  Future<void> _importFromDisk({required bool white}) async {
    final picked = await widget.pickPgn();
    if (picked == null || !mounted) return;
    if (picked.error != null) {
      _say(picked.error!, isError: true);
      return;
    }
    final import = picked.result;
    if (import == null) return;

    // The file's own move tree says which side it trains. When that
    // disagrees with the section the user pressed, one question — because
    // the answer is written into the chapter's `// Color:` header for good,
    // and a Black book designated as White reports nonsense on every game.
    final looksLike = picked.suggestedColor;
    final section = white ? 'White' : 'Black';
    if (looksLike != null && looksLike != section) {
      final proceed = await confirmAction(
        context,
        title: 'This looks like a $looksLike repertoire',
        message:
            'Its lines are written from the $looksLike side. Add it as your '
            '$section book anyway?',
        confirmLabel: 'Add as $section',
        destructive: false,
      );
      if (!proceed || !mounted) return;
    }

    final name = _uniqueName(
      picked.suggestedName ?? 'Imported repertoire',
      _takenNames,
    );
    await _createAndDesignate(
      white: white,
      name: name,
      chapterName: name,
      pgnContent: import.pgnContent,
      gameCount: import.gameCount,
      done: (lines) =>
          '$name is now your $section book — $lines '
          '${lines == 1 ? 'line' : 'lines'} imported.',
    );
  }

  /// [base], or the first of "base 2", "base 3", … not already in use.
  static String _uniqueName(String base, Set<String> taken) {
    final trimmed = base.trim().isEmpty ? 'Imported repertoire' : base.trim();
    if (!taken.contains(trimmed.toLowerCase())) return trimmed;
    for (var n = 2; ; n++) {
      final candidate = '$trimmed $n';
      if (!taken.contains(candidate.toLowerCase())) return candidate;
    }
  }

  Future<void> _createEmpty({required bool white}) async {
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => _NameRepertoireDialog(
        title: 'Name the new repertoire',
        initial: '',
        taken: _takenNames,
      ),
    );
    if (name == null || !mounted) return;

    await _createAndDesignate(
      white: white,
      name: name,
      done: (_) => '$name added. Build its lines in the Repertoire Builder.',
    );
  }

  Future<void> _createAndDesignate({
    required bool white,
    required String name,
    String chapterName = 'Main',
    String? pgnContent,
    int gameCount = 0,
    required String Function(int lines) done,
  }) async {
    try {
      final created = await createRepertoire(
        name: name,
        color: white ? 'White' : 'Black',
        chapterName: chapterName,
        pgnContent: pgnContent,
        gameCount: gameCount,
      );
      await _settings.addPath(white: white, path: created.directoryPath);
      // The count after import, not the file's: a study's variations are
      // written as lines of their own.
      _say(done(created.gameCount));
    } catch (e) {
      debugPrint('Create repertoire failed: $e');
      _say(AppMessages.createRepertoireFailed, isError: true);
    }
  }

  void _say(String message, {bool isError = false}) {
    if (!mounted) return;
    showAppSnackBar(context, message, isError: isError);
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
            candidates: _candidatesFor(white: true),
            mismatchFor: (path) =>
                _colorMismatches[_mismatchKey(white: true, path: path)],
            onImport: () => _importFromDisk(white: true),
            onDesignate: (r) =>
                _settings.addPath(white: true, path: r.filePath),
            onCreateEmpty: () => _createEmpty(white: true),
            onRemove: (path) => _settings.removePath(white: true, path: path),
          ),
          const SizedBox(height: 16),
          _ColorDesignation(
            label: 'As Black',
            paths: _settings.blackPaths,
            candidates: _candidatesFor(white: false),
            mismatchFor: (path) =>
                _colorMismatches[_mismatchKey(white: false, path: path)],
            onImport: () => _importFromDisk(white: false),
            onDesignate: (r) =>
                _settings.addPath(white: false, path: r.filePath),
            onCreateEmpty: () => _createEmpty(white: false),
            onRemove: (path) => _settings.removePath(white: false, path: path),
          ),
        ],
      ),
    );
  }
}

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

/// One colour: its heading with the two add controls, then its books.
class _ColorDesignation extends StatelessWidget {
  const _ColorDesignation({
    required this.label,
    required this.paths,
    required this.candidates,
    required this.mismatchFor,
    required this.onImport,
    required this.onDesignate,
    required this.onCreateEmpty,
    required this.onRemove,
  });

  final String label;
  final List<String> paths;

  /// Repertoires in the app that are not yet this colour's book.
  final List<RepertoireMetadata> candidates;

  /// Chapter names in this folder marked for the *other* color, or null.
  final List<String>? Function(String path) mismatchFor;
  final VoidCallback onImport;
  final ValueChanged<RepertoireMetadata> onDesignate;
  final VoidCallback onCreateEmpty;
  final ValueChanged<String> onRemove;

  static String _displayName(String path) => path.split(RegExp(r'[/\\]')).last;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Wrap, not Row: the panel is also the Settings page's Repertoires
        // section, which is 320px wide on a narrow window — too narrow for
        // the colour and both buttons on one line. A Row gave the label the
        // leftover zero width and wrapped it one character per line.
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 6,
          children: [
            Text(
              label,
              style: AppTextStyles.body.copyWith(fontWeight: FontWeight.w600),
            ),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 6,
              runSpacing: 6,
              children: [
                Tooltip(
                  message:
                      'Pick a .pgn file — a study or repertoire exported from '
                      'anywhere — and make it this book',
                  child: FilledButton.tonalIcon(
                    onPressed: onImport,
                    icon: const Icon(Icons.file_open_outlined, size: 16),
                    label: const Text('Import PGN…'),
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ),
                _AddExistingMenu(
                  candidates: candidates,
                  onDesignate: onDesignate,
                  onCreateEmpty: onCreateEmpty,
                ),
              ],
            ),
          ],
        ),
        if (paths.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'None yet — games you play as ${label.substring(3)} are not '
              'checked.',
              style: AppTextStyles.caption,
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
                    tooltip: 'Stop checking games against this book',
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

/// "Add existing ▾": the repertoires already in the app that are not this
/// colour's book yet, and a way to start an empty one. A menu, not a dialog:
/// the list is short and the choice is one click.
class _AddExistingMenu extends StatelessWidget {
  const _AddExistingMenu({
    required this.candidates,
    required this.onDesignate,
    required this.onCreateEmpty,
  });

  final List<RepertoireMetadata> candidates;
  final ValueChanged<RepertoireMetadata> onDesignate;
  final VoidCallback onCreateEmpty;

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      menuChildren: [
        if (candidates.isEmpty)
          const MenuItemButton(
            onPressed: null,
            child: Text('No other repertoires in the app'),
          )
        else
          for (final r in candidates)
            MenuItemButton(
              leadingIcon: const Icon(Icons.menu_book_outlined, size: 16),
              onPressed: () => onDesignate(r),
              child: Text(r.name),
            ),
        const Divider(height: 1),
        MenuItemButton(
          leadingIcon: const Icon(Icons.create_new_folder_outlined, size: 16),
          onPressed: onCreateEmpty,
          child: const Text('New empty repertoire…'),
        ),
      ],
      builder: (context, controller, _) => Tooltip(
        message: 'Use a repertoire already in the app as this book',
        child: OutlinedButton.icon(
          onPressed: () =>
              controller.isOpen ? controller.close() : controller.open(),
          icon: const Icon(Icons.arrow_drop_down, size: 18),
          iconAlignment: IconAlignment.end,
          label: const Text('Add existing'),
          style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
        ),
      ),
    );
  }
}
