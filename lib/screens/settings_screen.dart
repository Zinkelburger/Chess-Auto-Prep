/// Flat shared preferences and directly editable view settings.
library;

import '../features/settings/widgets/settings_section_status.dart';
import 'package:chess_auto_prep/features/settings/models/board_display_configuration.dart';

import '../app/legacy_theme_boundary.dart';
import '../design_system/theme/app_typography.dart';
import '../features/settings/widgets/appearance_settings.dart';
import '../l10n/generated/app_localizations.dart';

import 'dart:async';

import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../features/updates/widgets/app_updates.dart';
import '../constants/engine_defaults.dart';
import '../core/app_state.dart';
import '../features/games/widgets/my_repertoires_section.dart';
import '../features/settings/controllers/board_display_settings.dart';
import '../features/settings/controllers/engine_settings.dart';
import '../features/settings/controllers/bulk_analysis_settings.dart';
import '../features/settings/controllers/eval_database_settings.dart';
import '../features/settings/models/settings_state.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../utils/app_messages.dart';
import '../utils/app_shortcuts.dart';
import 'package:chess_auto_prep/features/settings/widgets/san_display.dart';
import '../widgets/chess_board_widget.dart';
import '../widgets/analysis/stockfish_settings_dialog.dart';
import '../widgets/analysis/analysis_panels_dialog.dart';
import '../design_system/components/list_search_field.dart';
import '../features/databases/widgets/databases_screen.dart';
import '../design_system/components/confirm_dialog.dart';
import '../widgets/settings/account_settings_section.dart';
import '../widgets/settings/settings_widgets.dart';
import '../widgets/settings/settings_navigation.dart';
import '../widgets/settings/keyboard_shortcuts_section.dart';
import '../widgets/shortcut_tooltip.dart';
import '../infrastructure/diagnostics/app_log_file.dart';
import '../utils/open_in_file_manager.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    this.initialMode,
    this.initialChapter = 0,
    this.initialGlobalSection = 0,
    this.viewContentBuilder,
  });
  final AppMode? initialMode;
  // Kept as deep-link input; chapters now resolve to a flat section.
  final int initialChapter;
  final int initialGlobalSection;
  final WidgetBuilder? viewContentBuilder;
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static final _projectUri = Uri.parse(
    'https://github.com/Zinkelburger/Chess-Auto-Prep',
  );
  late final _engine = context.read<EngineSettings>();
  late int _selected;
  AppMode? _mode;
  String _query = '';
  final _visitedGlobals = <int>{};
  final _visitedViews = <AppMode>{};
  late ViewSettingsRegistry _registry;
  final _navigationScroll = ScrollController();
  bool get _global => _mode == null;
  String _sectionLabel(int index) => index == 7
      ? AppLocalizations.of(context).appearance
      : _sections[index].label;
  static const _sections = [
    (
      label: 'Accounts',
      icon: Icons.person_outline,
      words: 'username lichess chess.com login token connect',
    ),
    (
      label: 'Board & moves',
      icon: Icons.grid_on_outlined,
      words: 'coordinates legal dots notation symbols display',
    ),
    (
      label: 'Repertoires',
      icon: Icons.menu_book_outlined,
      words: 'white black books import pgn side board size',
    ),
    (
      label: 'Analysis',
      icon: Icons.tune,
      words:
          'engine stockfish cores cpu memory depth lines maia rating panels expectimax evaluations',
    ),
    (
      label: 'Data & storage',
      icon: Icons.storage_outlined,
      words:
          'database master games years download lichess chessdb offline online quota cache trash folder',
    ),
    (
      label: 'App',
      icon: Icons.info_outline,
      words: 'about update install version reset defaults licenses github',
    ),
    (
      label: 'Shortcuts',
      icon: Icons.keyboard_outlined,
      words: 'keyboard keys reference',
    ),
    (
      label: 'Appearance',
      icon: Icons.brightness_6_outlined,
      words: 'theme light dark system display',
    ),
  ];
  static const _views = [
    (
      mode: AppMode.repertoireTrainer,
      label: 'Training',
      words:
          'session learn review schedule repetition lines quiz delay speed chapters grouping side unlimited whole depth correct answers streak replay missed difficulty rating next introduction comments separator file',
    ),
    (
      mode: AppMode.tactics,
      label: 'Tactics',
      words:
          'puzzle order mistakes blunders inaccuracies expiry winning downloads games time controls startup age dates unreviewed star alternative group book review per site',
    ),
    (
      mode: AppMode.pgnViewer,
      label: 'Game viewer',
      words:
          'pgn playback speed autosave opening eco orientation move list variations top middle bottom expand fold current anchor',
    ),
    (
      mode: AppMode.repertoire,
      label: 'Repertoires',
      words: 'books white black import pgn side board size',
    ),
    (
      mode: AppMode.engineTournament,
      label: 'Tournament engines',
      words: 'uci executable add test verify options threads hash ponder',
    ),
    (
      mode: AppMode.bughouse,
      label: 'Bughouse',
      words: 'engine cpu cores lines memory time batch',
    ),
  ];

  @override
  void initState() {
    super.initState();
    _selected = widget.initialGlobalSection;
    _mode = widget.initialMode == AppMode.repertoireLibrary
        ? AppMode.repertoire
        : widget.initialMode;
    if (_mode == AppMode.playersPrep) {
      _mode = null;
      _selected = 0;
    }
    if (_mode == AppMode.databases) {
      _mode = null;
      _selected = 4;
    }
    if (_mode == AppMode.study ||
        _mode == AppMode.positionAnalysis ||
        (_mode == AppMode.repertoire && widget.initialChapter == 1) ||
        (_mode == AppMode.pgnViewer && widget.initialChapter == 2)) {
      _mode = null;
      _selected = 3;
    }
    if (_mode == null && _selected == 2) _mode = AppMode.repertoire;
    if (_global) {
      _visitedGlobals.add(_selected);
    } else {
      _visitedViews.add(_mode!);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _registry = ViewSettingsRegistry.forApp(context.read<AppState>());
    if (_mode != null && widget.viewContentBuilder == null) {
      _requestView(_mode!);
    }
  }

  void _requestView(AppMode mode) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _registry.requestView(mode);
    });
  }

  @override
  void dispose() {
    _navigationScroll.dispose();
    super.dispose();
  }

  void _selectGlobal(int index) {
    if (!mounted) return;
    setState(() {
      _mode = null;
      _selected = index;
      _visitedGlobals.add(index);
    });
  }

  void _selectView(AppMode mode) {
    if (!mounted || !mode.isAvailable) return;
    setState(() {
      _mode = mode;
      _visitedViews.add(mode);
    });
    _requestView(mode);
  }

  bool _matches(String label, String words) => _query
      .trim()
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .every((term) => '$label $words'.toLowerCase().contains(term));
  List<Widget> _navigation() => [
    for (final i in [7, 0, 1, 3])
      if (_matches(_sectionLabel(i), _sections[i].words)) _globalNavTile(i),
    for (final view in _views)
      if (view.mode.isAvailable && _matches(view.label, view.words))
        ListTile(
          key: ValueKey('settings-view-${view.mode.name}'),
          dense: true,
          minTileHeight: 38,
          selected: _mode == view.mode,
          selectedTileColor: Theme.of(
            context,
          ).colorScheme.primary.withValues(alpha: .12),
          title: Text(
            view.label,
            style: _mode == view.mode
                ? AppTypography.bodyStrong(context)
                : AppTypography.body(context),
          ),
          onTap: () => _selectView(view.mode),
        ),
    for (final i in [4, 5, 6])
      if (_matches(_sectionLabel(i), _sections[i].words)) _globalNavTile(i),
  ];

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Theme.of(context).colorScheme.surface,
    appBar: AppBar(
      title: Text('Settings', style: AppTypography.bodyStrong(context)),
      automaticallyImplyLeading: false,
      actions: [
        ShortcutIconButton(
          description: 'Close settings',
          shortcut: AppShortcut.leave,
          icon: const Icon(Icons.close, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        const SizedBox(width: 4),
      ],
    ),
    body: LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 760;
        final navigation = _navigation();
        final search = Padding(
          padding: const EdgeInsets.all(12),
          child: ListSearchField(
            hintText: 'Find a setting',
            onChanged: (value) {
              if (mounted) setState(() => _query = value);
            },
          ),
        );
        final content = Expanded(
          child: ListenableBuilder(
            listenable: Listenable.merge([_engine, _registry]),
            builder: (context, _) => IndexedStack(
              index: _global
                  ? _selected
                  : _sections.length +
                        _views.indexWhere((v) => v.mode == _mode),
              children: [
                for (var i = 0; i < _sections.length; i++)
                  if (!_visitedGlobals.contains(i))
                    const SizedBox.shrink()
                  else if (i == 7)
                    const AppearanceSettings()
                  else if (i == 4)
                    const LegacyThemeBoundary(
                      child: DatabasesScreen(embedded: true),
                    )
                  else
                    LegacyThemeBoundary(child: _globalPage(i, compact)),
                for (final view in _views)
                  if (_visitedViews.contains(view.mode))
                    LegacyThemeBoundary(child: _viewContent(view.mode))
                  else
                    const SizedBox.shrink(),
              ],
            ),
          ),
        );
        if (compact) {
          return Column(
            children: [
              search,
              SizedBox(
                height: 48,
                child: navigation.isEmpty
                    ? const Center(child: Text('No matching settings'))
                    : ListView(
                        scrollDirection: Axis.horizontal,
                        children: [
                          for (final tile in navigation)
                            SizedBox(width: 170, child: tile),
                        ],
                      ),
              ),
              const Divider(height: 1),
              content,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 220,
              child: Column(
                children: [
                  search,
                  Expanded(
                    child: Scrollbar(
                      controller: _navigationScroll,
                      child: ListView(
                        key: const Key('settings-navigation'),
                        controller: _navigationScroll,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        children: navigation.isEmpty
                            ? [
                                const ListTile(
                                  title: Text('No matching settings'),
                                ),
                              ]
                            : navigation,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const VerticalDivider(width: 1),
            content,
          ],
        );
      },
    ),
  );

  Widget _globalNavTile(int index) => ListTile(
    key: Key('settings-nav-$index'),
    dense: true,
    minTileHeight: 38,
    selected: _global && _selected == index,
    selectedTileColor: Theme.of(
      context,
    ).colorScheme.primary.withValues(alpha: .12),
    title: Text(
      _sectionLabel(index),
      style: _global && _selected == index
          ? AppTypography.bodyStrong(context)
          : AppTypography.body(context),
    ),
    onTap: () => _selectGlobal(index),
  );

  Widget _globalPage(int index, bool compact) => ListView(
    key: PageStorageKey('settings-page-$index'),
    padding: EdgeInsets.all(compact ? 16 : 24),
    children: [
      Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(_sections[index].label, style: AppTextStyles.bodyStrong),
              const SizedBox(height: 12),
              ...switch (index) {
                0 => const [ChessUsernamesSection(), LichessLoginSection()],
                1 => [_buildDisplaySection()],
                2 => const [MyRepertoiresSection()],
                3 => [
                  const Text(
                    'Shared by board analysis across the app. Game analysis depth is used by reviews and new builds.',
                    style: AppTextStyles.muted,
                  ),
                  const SizedBox(height: 12),
                  const StockfishSettingsBody(),
                  _buildMaiaSection(),
                  const SettingsGroup(
                    title: 'Analysis panels and move tables',
                    icon: Icons.view_column,
                    subtitle:
                        'Shared across views that show these panels. Study uses the board engine controls above.',
                    children: [AnalysisPanelsSettingsBody()],
                  ),
                ],
                5 => [
                  const UpdateSettingsSection(),
                  _buildAboutSection(),
                  _buildResetButton(),
                ],
                6 => const [KeyboardShortcutsSection()],
                _ => <Widget>[],
              },
            ],
          ),
        ),
      ),
    ],
  );

  Widget _viewContent(AppMode mode) {
    final builder =
        mode == widget.initialMode && widget.viewContentBuilder != null
        ? widget.viewContentBuilder
        : _registry.entries[mode]?.builder;
    return Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
              child: Text(
                _views.firstWhere((v) => v.mode == mode).label,
                style: AppTextStyles.bodyStrong,
              ),
            ),
            Expanded(
              child: builder == null
                  ? const Center(
                      child: Text(
                        'Loading settings…',
                        style: AppTextStyles.muted,
                      ),
                    )
                  : Builder(key: ValueKey(mode), builder: builder),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openProject() async {
    var opened = false;
    try {
      opened = await launchUrl(
        _projectUri,
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      opened = false;
    }
    if (!opened && mounted) {
      showAppSnackBar(
        context,
        'Could not open the Chess Auto Prep GitHub page',
        isError: true,
      );
    }
  }

  /// Show the user where the app writes what went wrong, so a bug report can
  /// carry the log instead of a remembered colour.
  Future<void> _openLogFolder() async {
    var opened = false;
    try {
      opened = await openInFileManager((await AppLogFile.directory()).path);
    } catch (_) {
      opened = false;
    }
    if (!opened && mounted) {
      showAppSnackBar(context, 'Could not open the log folder', isError: true);
    }
  }

  Widget _buildAboutSection() {
    return SettingsGroup(
      title: 'About & open source',
      icon: Icons.info_outline,
      children: [
        ListTile(
          titleTextStyle: AppTextStyles.bodyStrong,
          subtitleTextStyle: AppTextStyles.muted,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 8,
          ),
          leading: const Icon(Icons.code, size: 22),
          title: const Text('Chess Auto Prep on GitHub'),
          subtitle: const Text('Source code, releases, and issue tracker'),
          trailing: const Icon(Icons.open_in_new, size: 17),
          onTap: () => unawaited(_openProject()),
        ),
        const Divider(
          height: 1,
          indent: 20,
          endIndent: 20,
          color: AppColors.divider,
        ),
        ListTile(
          key: const Key('settings-open-log-folder'),
          titleTextStyle: AppTextStyles.bodyStrong,
          subtitleTextStyle: AppTextStyles.muted,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 8,
          ),
          leading: const Icon(Icons.article_outlined, size: 22),
          title: const Text('Open log folder'),
          subtitle: const Text(
            'Errors are written to app.log — attach it to a bug report',
          ),
          trailing: const Icon(Icons.open_in_new, size: 17),
          onTap: () => unawaited(_openLogFolder()),
        ),
        const Divider(
          height: 1,
          indent: 20,
          endIndent: 20,
          color: AppColors.divider,
        ),
        ListTile(
          titleTextStyle: AppTextStyles.bodyStrong,
          subtitleTextStyle: AppTextStyles.muted,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 8,
          ),
          leading: const Icon(Icons.balance_outlined, size: 22),
          title: const Text('Open-source licenses'),
          subtitle: const Text(
            'Includes Hivemind by aminwoo, the MIT-licensed bughouse engine',
          ),
          trailing: const Icon(Icons.chevron_right, size: 20),
          onTap: () => showLicensePage(
            context: context,
            applicationName: 'Chess Auto Prep',
          ),
        ),
      ],
    );
  }

  // ── Display section ────────────────────────────────────────────────────────

  /// Board coordinates, legal destinations and piece notation. Global on purpose —
  /// a board that is labelled in Tactics and bare in Study is two boards to
  /// learn. The preview under the controls is live, so the choice is seen
  /// before the screen is left.
  Widget _buildDisplaySection() {
    return ListenableBuilder(
      listenable: context.read<BoardDisplaySettings>(),
      builder: (context, _) {
        final display = context.read<BoardDisplaySettings>();
        return SettingsGroup(
          title: 'Board and moves',
          icon: Icons.grid_on_outlined,
          children: [
            SettingsSectionStatus(
              owner: display,
              policy: 'Saved display changes apply to all boards immediately.',
            ),
            SettingsChoiceTile<BoardCoordinates>(
              label: 'Board coordinates',
              value: display.editing.coordinates,
              items: const [
                (BoardCoordinates.none, 'Off'),
                (BoardCoordinates.inside, 'Inside the board'),
                (BoardCoordinates.outside, 'Outside the board'),
                (BoardCoordinates.everySquare, 'Every square'),
              ],
              onChanged: (v) => unawaited(
                display.setCoordinates(v).catchError((Object _) {}),
              ),
            ),
            SettingsSwitchTile(
              label: 'Show legal moves',
              description: 'Show possible destinations when selecting a piece',
              value: display.editing.showLegalMoves,
              onChanged: (value) => unawaited(
                display.setShowLegalMoves(value).catchError((Object _) {}),
              ),
            ),
            SettingsChoiceTile<PieceNotation>(
              label: 'Piece notation',
              value: display.editing.pieceNotation,
              items: const [
                (PieceNotation.letters, 'Letters (KQRBN)'),
                (PieceNotation.figurines, 'Figurines (♔♕♖♗♘)'),
              ],
              onChanged: (v) => unawaited(
                display.setPieceNotation(v).catchError((Object _) {}),
              ),
            ),
            const Divider(
              height: 1,
              indent: 20,
              endIndent: 20,
              color: AppColors.divider,
            ),
            _DisplayPreview(settings: display),
          ],
        );
      },
    );
  }

  // ── Engine section ─────────────────────────────────────────────────────────

  Widget _buildMaiaSection() => ListenableBuilder(
    listenable: _engine,
    builder: (context, _) => Column(
      children: [
        SettingsSectionStatus(
          owner: _engine,
          policy: 'Saved prediction changes apply to the next position.',
        ),
        SettingsStepperTile(
          label: 'Opponent rating for predictions',
          description: 'Maia predictions',
          value: _engine.editing.maiaElo,
          min: kMinMaiaElo,
          max: kMaxMaiaElo,
          step: 100,
          suffix: 'Elo',
          onChanged: (v) => _engine.maiaElo = v,
        ),
      ],
    ),
  );

  // ── Reset button ───────────────────────────────────────────────────────────

  /// Put every engine, analysis and database setting back to its default.
  ///
  /// The reset runs after the dialog closes rather than inside its button, so
  /// the await is not racing a widget that is being torn down.
  Future<void> _confirmResetToDefaults() async {
    final confirmed = await confirmAction(
      context,
      title: 'Reset analysis, board and data preferences?',
      message:
          'Reset engine, analysis, display, and database preferences to '
          'factory defaults?',
      confirmLabel: 'Reset',
    );
    if (!confirmed) return;
    if (!mounted) return;
    final bulk = context.read<BulkAnalysisSettings>();
    final display = context.read<BoardDisplaySettings>();
    final databases = context.read<EvalDatabaseSettings>();
    try {
      await _engine.resetToDefaults();
      await bulk.setDepth(BulkAnalysisSettings.defaultDepth);
      await databases.resetToDefaults();
      await display.resetToDefaults();
      if (mounted) showAppSnackBar(context, 'Settings restored to defaults');
    } catch (_) {
      if (mounted)
        showAppSnackBar(
          context,
          'Some preferences could not be saved. Retry the failed section.',
        );
    }
  }

  Widget _buildResetButton() {
    final databases = context.watch<EvalDatabaseSettings>();
    return SettingsGroup(
      title: 'Reset analysis, board and data preferences',
      icon: Icons.restore,
      subtitle:
          'Reset engine, analysis, display and database preferences. Your accounts, games and repertoires are kept.',
      children: [
        if (databases.state.phase == SettingsPhase.failed)
          SettingsSectionStatus(
            owner: databases,
            policy: 'Database preferences are saved.',
          ),
        Padding(
          padding: const EdgeInsets.all(20),
          child: Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.restore, size: 18),
              label: const Text('Reset settings…'),
              onPressed: () => unawaited(_confirmResetToDefaults()),
            ),
          ),
        ),
      ],
    );
  }
}

/// A board and a line of moves drawn with the current Display preferences.
class _DisplayPreview extends StatelessWidget {
  const _DisplayPreview({required this.settings});

  final BoardDisplaySettings settings;

  /// After 1.e4 e5 2.Nf3 Nc6 3.Bb5: a few pieces out, so the coordinates
  /// have something to be read against.
  static final Position _position = () {
    Position pos = Chess.initial;
    for (final san in const ['e4', 'e5', 'Nf3', 'Nc6', 'Bb5']) {
      pos = pos.play(pos.parseSan(san)!);
    }
    return pos;
  }();

  static const _line = ['e4', 'e5', 'Nf3', 'Nc6', 'Bb5', 'a6', 'Bxc6', 'dxc6'];

  @override
  Widget build(BuildContext context) {
    final figurines = settings.pieceNotation == PieceNotation.figurines;
    final buffer = StringBuffer();
    for (var i = 0; i < _line.length; i++) {
      if (i.isEven) buffer.write('${i ~/ 2 + 1}. ');
      buffer.write(figurines ? figurineSan(_line[i]) : _line[i]);
      buffer.write(' ');
    }
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 200,
            height: 200,
            child: ChessBoardWidget(
              key: const Key('display-preview-board'),
              position: _position,
              enableUserMoves: false,
              coordinates: settings.coordinates,
            ),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Preview', style: AppTextStyles.bodyStrong),
                const SizedBox(height: 8),
                Text(
                  buffer.toString().trimRight(),
                  key: const Key('display-preview-line'),
                  style: AppTextStyles.mono,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
