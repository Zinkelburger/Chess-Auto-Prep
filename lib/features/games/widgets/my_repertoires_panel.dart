import 'package:flutter/material.dart';

import '../../../models/repertoire_metadata.dart';
import '../../../services/pgn_parsing_service.dart' as pgn;
import '../../../services/storage/storage_factory.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../../../widgets/common/searchable_picker_dialog.dart';
import '../services/my_repertoire_settings.dart';

/// Designate which repertoire folders are the books you actually play as
/// White and as Black — the ones every game gets checked against.
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
    _settings.ensureLoaded().then((_) => _refreshColorCheck());
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

  Future<void> _addRepertoire({required bool white}) async {
    final all = await StorageFactory.instance.listRepertoires();
    if (!mounted) return;
    final existing = _settings.pathsFor(white: white);
    final candidates = [
      for (final r in all)
        if (!existing.contains(r.filePath)) r,
    ];
    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No further repertoires to add.')),
      );
      return;
    }
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
