/// Shared settings shell with expandable view chapters and global preferences.
library;

import 'dart:async';

import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../features/updates/widgets/app_updates.dart';
import '../constants/engine_defaults.dart';
import '../core/app_state.dart';
import '../features/games/widgets/my_repertoires_section.dart';
import '../models/board_display_settings.dart';
import '../models/engine_settings.dart';
import '../models/eval_database_settings.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../utils/app_messages.dart';
import '../utils/app_shortcuts.dart';
import '../utils/san_display.dart';
import '../utils/system_info.dart';
import '../widgets/chess_board_widget.dart';
import '../widgets/analysis/stockfish_settings_dialog.dart';
import '../widgets/analysis/analysis_panels_dialog.dart';
import '../widgets/common/choice_field.dart';
import '../widgets/common/confirm_dialog.dart';
import '../widgets/settings/account_settings_section.dart';
import '../widgets/settings/settings_widgets.dart';
import '../widgets/settings/settings_navigation.dart';
import '../widgets/settings/keyboard_shortcuts_section.dart';
import '../widgets/shortcut_tooltip.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    this.initialMode,
    this.initialChapter = 0,
    this.initialGlobalSection = 0,
    this.viewContentBuilder,
  });

  final AppMode? initialMode;
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

  final _engine = EngineSettings.instance;
  late int _selected = widget.initialGlobalSection;
  late AppMode? _mode = widget.initialMode;
  late int _chapter = widget.initialChapter;
  bool get _global => _mode == null;
  late ViewSettingsRegistry _registry;
  final _navigationScroll = ScrollController();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _registry = ViewSettingsRegistry.forApp(context.read<AppState>());
    if (_mode != null) {
      if (!_registry.entries.containsKey(_mode!) &&
          widget.viewContentBuilder == null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _mode != null) _selectView(_mode!, chapter: _chapter);
        });
      }
    }
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
    });
  }

  void _selectView(AppMode mode, {int chapter = 0}) {
    final app = context.read<AppState>();
    if (!mounted ||
        !mode.isAvailable ||
        (app.isRepertoireGenerating && mode != app.currentMode)) {
      return;
    }
    setState(() {
      _mode = mode;
      _chapter = chapter;
    });
    // Mount lazy feature controllers while keeping this settings route open.
    if (mode != app.currentMode) {
      app.setMode(mode);
    }
  }

  static const _sections = [
    (
      label: 'Accounts',
      icon: Icons.person_outline,
      description: 'Your chess identities and connected services.',
    ),
    (
      label: 'Display',
      icon: Icons.grid_on_outlined,
      description: 'How boards and moves are drawn, everywhere in the app.',
    ),
    (
      label: 'Repertoires',
      icon: Icons.menu_book_outlined,
      description: 'Choose the opening books you play.',
    ),
    (
      label: 'Engine',
      icon: Icons.tune,
      description: 'How much of this computer Stockfish may use.',
    ),
    (
      label: 'Data',
      icon: Icons.storage_outlined,
      description: 'Manage local databases and online lookups.',
    ),
    (
      label: 'About',
      icon: Icons.info_outline,
      description: 'Project information and app maintenance.',
    ),
    (
      label: 'Keyboard shortcuts',
      icon: Icons.keyboard_outlined,
      description: 'The essentials for the current view.',
    ),
    (
      label: 'Engine analysis',
      icon: Icons.search,
      description:
          'Stockfish search and move-table preferences, shared across analysis views.',
    ),
    (
      label: 'Analysis panels',
      icon: Icons.view_column_outlined,
      description:
          'Choose which engine and reference panels appear alongside your board.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surface,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        titleSpacing: 8,
        title: const Text('Settings', style: AppTextStyles.title),
        // The way out sits where the gear that opened this screen was, so the
        // pointer is already over it; a back arrow on the far left left users
        // hunting for the exit.
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
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, color: AppColors.divider),
        ),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 760;
          final content = Expanded(
            child: ListenableBuilder(
              listenable: _engine,
              builder: (context, _) => IndexedStack(
                index: _global ? 0 : 1,
                children: [
                  IndexedStack(
                    index: _selected,
                    children: [
                      _page(0, const [
                        ChessUsernamesSection(),
                        LichessLoginSection(),
                      ], compact),
                      _page(1, [_buildDisplaySection()], compact),
                      _page(2, const [MyRepertoiresSection()], compact),
                      _page(3, [
                        _buildEngineSection(getLogicalCores()),
                        const SettingsGroup(
                          title: 'Looking for analysis settings?',
                          icon: Icons.settings_outlined,
                          subtitle:
                              'Choose Engine analysis or Analysis panels in this sidebar for search and panel preferences.',
                          children: [],
                        ),
                      ], compact),
                      _page(4, [_buildDatabasesSection()], compact),
                      _page(5, [
                        const UpdateSettingsSection(),
                        _buildAboutSection(),
                        _buildResetButton(),
                      ], compact),
                      _page(6, const [KeyboardShortcutsSection()], compact),
                      _page(7, const [StockfishSettingsBody()], compact),
                      _page(8, const [AnalysisPanelsSettingsBody()], compact),
                    ],
                  ),
                  ListenableBuilder(
                    listenable: _registry,
                    builder: (context, _) => _global
                        ? const SizedBox.shrink()
                        : _viewContent(compact),
                  ),
                ],
              ),
            ),
          );
          if (compact) {
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                  child: ChoiceField<int>(
                    key: const Key('settings-section-picker'),
                    label: 'Section',
                    helper: context.watch<AppState>().isRepertoireGenerating
                        ? 'View switching is paused while a repertoire is generating.'
                        : null,
                    value: _global
                        ? _selected
                        : -availableModeMenuOrder().indexOf(_mode!) - 1,
                    items: [
                      for (var i = 0; i < availableModeMenuOrder().length; i++)
                        if (!context.watch<AppState>().isRepertoireGenerating ||
                            availableModeMenuOrder()[i] ==
                                context.read<AppState>().currentMode)
                          ChoiceItem(
                            value: -i - 1,
                            label:
                                'Views · ${availableModeMenuOrder()[i].label}',
                          ),
                      for (var i = 0; i < _sections.length; i++)
                        ChoiceItem(
                          value: i,
                          label: 'Global · ${_sections[i].label}',
                          icon: _sections[i].icon,
                        ),
                    ],
                    onChanged: (value) {
                      if (value < 0) {
                        _selectView(availableModeMenuOrder()[-value - 1]);
                      } else {
                        _selectGlobal(value);
                      }
                    },
                  ),
                ),
                if (!_global)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                    child: ChoiceField<int>(
                      key: ValueKey('settings-chapter-picker-${_mode!.name}'),
                      label: 'Chapter',
                      value: _chapter,
                      items: [
                        for (
                          var i = 0;
                          i < settingsChapters(_mode!).length;
                          i++
                        )
                          ChoiceItem(
                            value: i,
                            label: settingsChapters(_mode!)[i].label,
                          ),
                      ],
                      onChanged: (value) => _selectView(_mode!, chapter: value),
                    ),
                  ),
                content,
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 248,
                child: Scrollbar(
                  controller: _navigationScroll,
                  thumbVisibility: true,
                  child: ListView(
                    controller: _navigationScroll,
                    padding: const EdgeInsets.fromLTRB(16, 28, 16, 24),
                    children: [
                      const Padding(
                        padding: EdgeInsets.fromLTRB(12, 0, 12, 16),
                        child: Text('VIEWS', style: AppTextStyles.eyebrow),
                      ),
                      for (final mode in availableModeMenuOrder()) ...[
                        ListTile(
                          key: ValueKey('settings-view-${mode.name}'),
                          minTileHeight: 40,
                          dense: true,
                          selected: _mode == mode,
                          title: Text(
                            mode.label,
                            style: AppTextStyles.bodyStrong,
                          ),
                          trailing: Icon(
                            _mode == mode
                                ? Icons.expand_more
                                : Icons.chevron_right,
                            size: 18,
                          ),
                          enabled:
                              !context
                                  .watch<AppState>()
                                  .isRepertoireGenerating ||
                              mode == context.read<AppState>().currentMode,
                          onTap: () => _selectView(mode),
                        ),
                        if (_mode == mode)
                          for (
                            var i = 0;
                            i < settingsChapters(mode).length;
                            i++
                          )
                            Padding(
                              padding: const EdgeInsets.only(left: 16),
                              child: ListTile(
                                key: ValueKey(
                                  'settings-chapter-${mode.name}-$i',
                                ),
                                minTileHeight: 36,
                                dense: true,
                                selected: _chapter == i,
                                selectedTileColor: AppColors.accent.withValues(
                                  alpha: 0.12,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                title: Text(
                                  settingsChapters(mode)[i].label,
                                  style: _chapter == i
                                      ? AppTextStyles.bodyStrong
                                      : AppTextStyles.body,
                                ),
                                onTap: () => _selectView(mode, chapter: i),
                              ),
                            ),
                      ],
                      const Padding(
                        padding: EdgeInsets.fromLTRB(12, 16, 12, 8),
                        child: Text('GLOBAL', style: AppTextStyles.eyebrow),
                      ),
                      for (var i = 0; i < 7; i++) ...[
                        _globalNavTile(i),
                        if (i == 3 &&
                            _global &&
                            const [3, 7, 8].contains(_selected)) ...[
                          Padding(
                            padding: const EdgeInsets.only(left: 24),
                            child: ListTile(
                              key: const Key('settings-engine-resources'),
                              minTileHeight: 36,
                              dense: true,
                              selected: _selected == 3,
                              title: const Text(
                                'Computer resources',
                                style: AppTextStyles.body,
                              ),
                              onTap: () => _selectGlobal(3),
                            ),
                          ),
                          _globalNavTile(7, nested: true),
                          _globalNavTile(8, nested: true),
                        ],
                      ],
                    ],
                  ),
                ),
              ),
              const VerticalDivider(width: 1, color: AppColors.divider),
              content,
            ],
          );
        },
      ),
    );
  }

  Widget _globalNavTile(int index, {bool nested = false}) {
    final selected = _global && _selected == index;
    return Padding(
      padding: EdgeInsets.only(left: nested ? 24 : 0, bottom: 2),
      child: ListTile(
        key: Key('settings-nav-$index'),
        minTileHeight: 36,
        dense: true,
        selected: selected,
        selectedTileColor: AppColors.accent.withValues(alpha: 0.12),
        selectedColor: AppColors.ink,
        iconColor: AppColors.onSurfaceMuted,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        leading: nested ? null : Icon(_sections[index].icon, size: 20),
        trailing: index == 3
            ? Icon(
                _global && const [3, 7, 8].contains(_selected)
                    ? Icons.expand_more
                    : Icons.chevron_right,
                size: 18,
              )
            : null,
        horizontalTitleGap: 12,
        title: Text(
          _sections[index].label,
          style: selected ? AppTextStyles.bodyStrong : AppTextStyles.body,
        ),
        onTap: () => _selectGlobal(index),
      ),
    );
  }

  Widget _viewContent(bool compact) {
    final mode = _mode!;
    final chapter = settingsChapters(mode)[_chapter];
    final entry = _registry.entries[mode];
    final builder =
        mode == widget.initialMode && widget.viewContentBuilder != null
        ? widget.viewContentBuilder
        : entry?.builder;
    return SettingsChapterScope(
      index: _chapter,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              compact ? 16 : 24,
              24,
              compact ? 16 : 24,
              0,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${mode.label} › ${chapter.label}',
                  style: AppTextStyles.title,
                ),
                const SizedBox(height: 8),
                Text(chapter.description, style: AppTextStyles.muted),
              ],
            ),
          ),
          Expanded(
            child: builder != null
                ? Builder(key: ValueKey(mode), builder: builder)
                : _viewPage(mode, compact),
          ),
        ],
      ),
    );
  }

  Widget _viewPage(AppMode mode, bool compact) {
    if (mode != AppMode.positionAnalysis &&
        mode != AppMode.study &&
        mode != AppMode.databases) {
      return const Center(
        child: Text('Loading view settings…', style: AppTextStyles.muted),
      );
    }
    return ListView(
      key: ValueKey('settings-default-${mode.name}-$_chapter'),
      padding: EdgeInsets.all(compact ? 16 : 24),
      children: [
        if (mode == AppMode.databases)
          _buildDatabasesSection()
        else if (_chapter == 0)
          const SettingsGroup(
            title: 'Analysis panels',
            icon: Icons.view_column,
            children: [AnalysisPanelsSettingsBody()],
          )
        else if (_chapter == 1)
          const SettingsGroup(
            title: 'Engine analysis',
            icon: Icons.memory,
            children: [StockfishSettingsBody()],
          )
        else
          _buildDisplaySection(),
      ],
    );
  }

  Widget _page(int index, List<Widget> children, bool compact) {
    final section = _sections[index];
    return ListView(
      key: PageStorageKey('settings-page-$index'),
      primary: false,
      padding: EdgeInsets.fromLTRB(
        compact ? 16 : 24,
        16,
        compact ? 16 : 24,
        24,
      ),
      children: [
        Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(section.label, style: AppTextStyles.title),
                const SizedBox(height: 8),
                Text(section.description, style: AppTextStyles.muted),
                const SizedBox(height: 16),
                ...children,
              ],
            ),
          ),
        ),
      ],
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

  Widget _buildAboutSection() {
    return SettingsGroup(
      title: 'About & open source',
      icon: Icons.info_outline,
      subtitle: 'Built in the open, for your chess preparation.',
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

  /// The two lila Display preferences a beginner asks for first: where the
  /// coordinates are, and whether a knight is an N or a ♘. Global on purpose —
  /// a board that is labelled in Tactics and bare in Study is two boards to
  /// learn. The preview under the controls is live, so the choice is seen
  /// before the screen is left.
  Widget _buildDisplaySection() {
    return ListenableBuilder(
      listenable: BoardDisplaySettings.instance,
      builder: (context, _) {
        final display = BoardDisplaySettings.instance;
        return SettingsGroup(
          title: 'Board and moves',
          icon: Icons.grid_on_outlined,
          subtitle: 'Changes apply immediately, to every board and move list.',
          children: [
            SettingsChoiceTile<BoardCoordinates>(
              label: 'Board coordinates',
              description: 'Where the file letters and rank numbers go.',
              value: display.coordinates,
              items: const [
                (BoardCoordinates.none, 'No'),
                (BoardCoordinates.inside, 'Inside the board'),
                (BoardCoordinates.outside, 'Outside the board'),
                (BoardCoordinates.everySquare, 'Every square'),
              ],
              onChanged: (v) => unawaited(display.setCoordinates(v)),
            ),
            SettingsChoiceTile<PieceNotation>(
              label: 'Piece notation',
              description: 'How a piece is written in a move.',
              value: display.pieceNotation,
              items: const [
                (PieceNotation.letters, 'Letters (KQRBN)'),
                (PieceNotation.figurines, 'Figurines (♔♕♖♗♘)'),
              ],
              onChanged: (v) => unawaited(display.setPieceNotation(v)),
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

  /// One number for CPU and one for memory. There used to be separate
  /// "workers" and "threads" rows, which are the same cores spent two ways
  /// (one process with N threads on the board, N processes reviewing games)
  /// and read as two different things to anyone who is not a programmer.
  Widget _buildEngineSection(int cores) {
    final peakMb = _engine.cores * _engine.hashMb;
    return SettingsGroup(
      title: 'Stockfish',
      icon: Icons.bolt,
      // No on/off switch here on purpose: starting and stopping Stockfish is
      // an action you want to see the result of, so it lives on the ⚡ button
      // next to the board.
      subtitle: 'Changes apply straight away. Type a number or use − and +.',
      children: [
        SettingsStepperTile(
          label: 'CPU cores',
          description:
              'This computer has $cores. Stockfish uses this many to analyse '
              'the board and to review your games. Leave some free if you run '
              'other programs at the same time.',
          value: _engine.cores,
          min: 1,
          max: cores,
          suffix: 'of $cores',
          onChanged: (v) => _engine.cores = v,
        ),
        SettingsStepperTile(
          label: 'Memory per engine',
          description:
              'RAM each Stockfish process keeps for positions it has already '
              'searched. Reviewing games runs one process per core, so that '
              'is up to $peakMb MB at once with the settings above.',
          value: _engine.hashMb,
          min: kMinHashMb,
          max: kMaxHashMb,
          step: 128,
          suffix: 'MB',
          onChanged: (v) => _engine.hashMb = v,
        ),
        SettingsStepperTile(
          label: 'Opponent rating',
          description:
              'Maia predicts what a human of this rating would play. Set it '
              'close to the opponents you actually face.',
          value: _engine.maiaElo,
          min: kMinMaiaElo,
          max: kMaxMaiaElo,
          step: 100,
          suffix: 'Elo',
          onChanged: (v) => _engine.maiaElo = v,
        ),
      ],
    );
  }

  // ── Databases section ──────────────────────────────────────────────────────

  /// A pointer, not a panel.
  ///
  /// Master games, your own games and the two offline evaluation stores each
  /// had a section here, and between them they filled more of this screen than
  /// everything else put together — while still not answering "how much disk
  /// is this using", because no section could see the others. They live on the
  /// Databases page now. What stays is the one switch that is a
  /// preference about *this machine's* network use rather than a fact about a
  /// store on its disk.
  Widget _buildDatabasesSection() {
    return SettingsGroup(
      title: 'Databases',
      icon: Icons.storage,
      subtitle: 'Review downloads, disk usage and updates in one place.',
      children: [
        ListTile(
          titleTextStyle: AppTextStyles.bodyStrong,
          subtitleTextStyle: AppTextStyles.muted,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 8,
          ),
          leading: const Icon(Icons.dns_outlined, size: 22),
          title: const Text('Open Databases'),
          subtitle: const Text(
            'Everything the app keeps on this machine, on one page',
          ),
          trailing: const Icon(Icons.chevron_right, size: 20),
          // Settings is a pushed route over the mode host, so switching mode
          // without popping would change the screen underneath and leave the
          // user still looking at Settings.
          onTap: () {
            final appState = context.read<AppState>();
            Navigator.pop(context);
            appState.setMode(AppMode.databases);
          },
        ),
        const Divider(
          height: 1,
          indent: 20,
          endIndent: 20,
          color: AppColors.divider,
        ),
        ListenableBuilder(
          listenable: EvalDatabaseSettings.instance,
          builder: (context, _) {
            final settings = EvalDatabaseSettings.instance;
            return SettingsValueRow(
              label: 'Online evaluation lookups',
              description:
                  'Allow on-demand expectimax to query ChessDB. Uses your daily API quota; repertoire builds have a separate setting.',
              control: Switch(
                value: settings.chessDbApiForExpectimax,
                onChanged: (value) =>
                    unawaited(settings.setChessDbApiForExpectimax(value)),
              ),
            );
          },
        ),
      ],
    );
  }

  // ── Reset button ───────────────────────────────────────────────────────────

  /// Put every engine, analysis and database setting back to its default.
  ///
  /// The reset runs after the dialog closes rather than inside its button, so
  /// the await is not racing a widget that is being torn down.
  Future<void> _confirmResetToDefaults() async {
    final confirmed = await confirmAction(
      context,
      title: 'Reset Settings',
      message:
          'Reset all engine, analysis, display, and database settings to '
          'factory defaults?',
      confirmLabel: 'Reset',
    );
    if (!confirmed) return;
    _engine.resetToDefaults();
    await EvalDatabaseSettings.instance.resetToDefaults();
    await BoardDisplaySettings.instance.resetToDefaults();
    if (mounted) showAppSnackBar(context, 'Settings restored to defaults');
  }

  Widget _buildResetButton() {
    return SettingsGroup(
      title: 'Restore defaults',
      icon: Icons.restore,
      subtitle:
          'Reset engine, analysis, display and database preferences. Your accounts, games and repertoires are kept.',
      children: [
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
