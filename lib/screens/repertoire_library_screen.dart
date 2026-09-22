import '../features/repertoire/services/repertoire_outline_service.dart';
import 'dart:async';
import '../features/repertoires/repositories/repertoire_catalog_repository.dart';
import '../app/legacy_theme_boundary.dart';
import '../features/repertoires/controllers/repertoire_catalog_controller.dart';
import '../design_system/layout/workspace_navigation_controller.dart';
import '../design_system/layout/workspace_shell.dart';
import '../app/navigation/workspace_destination_toolbar.dart';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../core/app_state.dart';
import '../features/repertoire/controllers/repertoire_outline_controller.dart';
import '../features/repertoire/widgets/repertoire_outline_panel.dart';
import '../features/repertoires/models/repertoire_metadata.dart';
import '../chess_core/pgn/pgn_text.dart' as pgn;
import '../services/storage/storage_factory.dart';
import '../theme/app_text_styles.dart';
import '../utils/app_messages.dart';
import '../widgets/app_breadcrumb_trail.dart';
import '../widgets/app_mode_switcher.dart';
import '../widgets/app_overflow_menu.dart';
import '../widgets/app_settings_button.dart';
import '../features/repertoires/widgets/repertoire_list_body.dart';

/// Material management independent of an editor, engine or training session.
/// Structural edits use the same controller and Undo as the builder outline.
class RepertoireLibraryScreen extends StatefulWidget {
  const RepertoireLibraryScreen({super.key});

  @override
  State<RepertoireLibraryScreen> createState() =>
      _RepertoireLibraryScreenState();
}

class _RepertoireLibraryScreenState extends State<RepertoireLibraryScreen> {
  late final RepertoireOutlineController _outline;
  AppState? _app;
  AppMode? _lastMode;
  RepertoireMetadata? _folder;
  final _workspaceNavigation = WorkspaceNavigationController();

  void _refreshCatalog() =>
      unawaited(context.read<RepertoireCatalogController>().refresh());
  int _openEpoch = 0;

  @override
  void initState() {
    super.initState();
    _outline = RepertoireOutlineController(
      service: context.read<RepertoireOutlineService>(),
      catalog: context.read<RepertoireCatalogRepository>(),
      onActiveChapterMoved: (path) {
        if (!mounted) return;
        _outline.setActiveChapter(path);
      },
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = context.read<AppState>();
    if (identical(app, _app)) return;
    _app?.removeListener(_modeChanged);
    _app = app;
    _lastMode = app.currentMode;
    app.addListener(_modeChanged);
  }

  void _modeChanged() {
    final mode = _app!.currentMode;
    final entering = mode == AppMode.repertoireLibrary && mode != _lastMode;
    _lastMode = mode;
    if (!entering || !mounted) return;
    // Other views can import, rename and edit the same material while this
    // IndexedStack child is parked. Refresh only on re-entry.
    if (_folder == null) {
      _refreshCatalog();
    } else {
      unawaited(_outline.refresh());
    }
  }

  Future<String?> _firstChapter(String folder) async {
    final storage = StorageFactory.instance;
    final chapters = await storage.listChapters(folder);
    if (chapters.isNotEmpty) return chapters.first.filePath;
    for (final child in await storage.listSubdirectories(folder)) {
      final path = await _firstChapter(child);
      if (path != null) return path;
    }
    return null;
  }

  Future<void> _openFolder(RepertoireMetadata folder, {String? chapter}) async {
    final epoch = ++_openEpoch;
    setState(() => _folder = folder);
    try {
      final storage = StorageFactory.instance;
      final first = chapter ?? await _firstChapter(folder.filePath);
      final content = first == null ? null : await storage.readFile(first);
      if (!mounted || epoch != _openEpoch) return;
      await _outline.open(
        rootPath: folder.filePath,
        activeChapterPath: first,
        isWhite:
            pgn.extractRepertoireColor(content ?? '')?.toLowerCase() != 'black',
      );
    } catch (_) {
      if (!mounted || epoch != _openEpoch) return;
      setState(() => _folder = null);
      showAppSnackBar(
        context,
        'Could not open that repertoire. Try again.',
        isError: true,
      );
    }
  }

  void _openChapterFolder(RepertoireMetadata chapter) {
    unawaited(
      _openFolder(
        RepertoireMetadata(
          filePath: p.dirname(chapter.filePath),
          name: p.basename(p.dirname(chapter.filePath)),
          lastModified: chapter.lastModified,
        ),
        chapter: chapter.filePath,
      ),
    );
  }

  void _backToLibrary() {
    if (!mounted) return;
    _openEpoch++;
    _outline.close();
    setState(() {
      _folder = null;
      _refreshCatalog();
    });
  }

  void _read(String path, {int? gameIndex}) {
    if (!mounted) return;
    context.read<AppState>().handOff(
      OpenPgnViewer(pgnPath: path, gameIndex: gameIndex),
    );
  }

  void _train(String path, {String? lineId}) {
    if (!mounted) return;
    context.read<AppState>().switchToTrainer(
      repertoirePath: path,
      lineId: lineId,
    );
  }

  @override
  void dispose() {
    _app?.removeListener(_modeChanged);
    _outline.dispose();
    _workspaceNavigation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => WorkspaceShell(
    navigation: _workspaceNavigation,
    destinationAppBar: WorkspaceDestinationToolbar(
      mode: AppMode.repertoireLibrary,
      navigation: _workspaceNavigation,
    ),
    appBar: AppBar(
      titleSpacing: 16,
      title: AppBarTitleWithTrail(
        title: _folder == null
            ? const SizedBox.shrink()
            : Row(
                children: [
                  IconButton(
                    onPressed: _backToLibrary,
                    tooltip: 'All repertoires',
                    icon: const Icon(Icons.arrow_back),
                  ),
                  Flexible(
                    child: Text(_folder!.name, overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
      ),
      actions: [
        AppOverflowMenu(
          entries: [
            AppMenuEntry(
              label: 'Refresh library',
              icon: Icons.refresh,
              onRun: () {
                if (!mounted) return;
                if (_folder == null) {
                  _refreshCatalog();
                } else {
                  unawaited(_outline.refresh());
                }
              },
            ),
          ],
        ),
        const AppModeSwitcher(),
        const AppSettingsButton(mode: AppMode.repertoireLibrary),
      ],
    ),
    body: IndexedStack(
      index: _folder == null ? 0 : 1,
      children: [
        ExcludeFocus(
          excluding: _folder != null,
          child: RepertoireListBody(
            onRepertoireSelected: (folder) => unawaited(_openFolder(folder)),
            onSelected: _openChapterFolder,
          ),
        ),
        if (_folder != null)
          LegacyThemeBoundary(
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1040),
                child: ListenableBuilder(
                  listenable: _outline,
                  builder: (context, _) {
                    final path = _outline.activeChapterPath;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Organize your repertoire',
                                style: AppTextStyles.title,
                              ),
                              const SizedBox(height: 8),
                              const Text(
                                'Drag chapters into folders and lines between chapters. Right-click for more actions.',
                                style: AppTextStyles.muted,
                              ),
                              const SizedBox(height: 16),
                              Wrap(
                                spacing: 12,
                                runSpacing: 8,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  FilledButton.icon(
                                    onPressed: () => _train(_folder!.filePath),
                                    icon: const Icon(Icons.school_outlined),
                                    label: const Text('Train repertoire'),
                                  ),
                                  if (path != null) ...[
                                    OutlinedButton.icon(
                                      onPressed: () => _read(path),
                                      icon: const Icon(
                                        Icons.menu_book_outlined,
                                      ),
                                      label: const Text('Read chapter'),
                                    ),
                                    OutlinedButton.icon(
                                      onPressed: () => _train(path),
                                      icon: const Icon(Icons.school_outlined),
                                      label: const Text('Train chapter'),
                                    ),
                                    TextButton.icon(
                                      onPressed: () {
                                        if (!mounted) return;
                                        context.read<AppState>().handOff(
                                          OpenBuilder(
                                            repertoirePath: path,
                                            reloadFromDisk: true,
                                          ),
                                        );
                                      },
                                      icon: const Icon(Icons.edit_outlined),
                                      label: const Text('Build chapter'),
                                    ),
                                    Text(
                                      p.basenameWithoutExtension(path),
                                      style: AppTextStyles.muted,
                                    ),
                                  ],
                                ],
                              ),
                            ],
                          ),
                        ),
                        const Divider(height: 1),
                        Expanded(
                          child: RepertoireOutlinePanel(
                            controller: _outline,
                            showPositionFilter: false,
                            onOpenChapter: (path) {
                              if (!mounted) return;
                              _outline.setActiveChapter(path);
                            },
                            onOpenLine: (path, line) =>
                                _read(path, gameIndex: line.gameIndex),
                            onTrainChapter: (path) => _train(path),
                            onTrainLine: (path, line) =>
                                _train(path, lineId: line.id),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          )
        else
          const SizedBox.shrink(),
      ],
    ),
  );
}
