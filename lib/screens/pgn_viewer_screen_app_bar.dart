// App-bar builders for the PGN viewer: title row with the open-PGN menu and
// slice chips, plus the study-mode / board-view / file action groups.
// Part of pgn_viewer_screen.dart.
part of 'pgn_viewer_screen.dart';

/// App-bar builders, split out of [_PgnViewerScreenState]. Depends on
/// [_RepertoireGenerationMixin] for the overflow menu's generate action.
mixin _AppBarBuildersMixin
    on State<PgnViewerScreen>, _RepertoireGenerationMixin {
  bool get _editMode;
  bool get _onLineTab;

  /// True while the viewer is showing one game handed to it by name (from the
  /// recent-games list). See [_PgnViewerScreenState._openFromHandoff].
  bool get _singleGameFocus;
  set _singleGameFocus(bool value);

  void _toggleEditMode();
  Future<void> _editInStudy();
  Future<void> _saveSliceAsStudy();
  void _openSliceDialog();
  void _showTrophyCabinet();
  Future<void> _exportSlice();
  Future<void> _exportSliceAsScid();
  Future<void> _pickFile();
  Future<void> _pastePgn();
  Future<void> _loadFile(String path);
  void _closeFile();
  bool _toggleSolitaireMode();
  @override
  void _reclaimFocus();

  PreferredSizeWidget _buildAppBar(ThemeData theme) {
    final fileName = _controller.filePath != null
        ? p.basename(_controller.filePath!)
        : '';
    return AppBar(
      titleSpacing: 16,
      leading:
          !_controller.showOpeningTree &&
              !_controller.isSolitaireMode &&
              _controller.hasTreeReturnPosition
          ? IconButton(
              onPressed: _controller.returnToTreePosition,
              icon: const Icon(Icons.arrow_back),
              tooltip: actionTooltip(
                'Back to opening-tree position',
                shortcut: AppShortcut.toggleOpeningTree,
              ),
            )
          : null,
      title: AppBarTitleWithTrail(
        title: Row(
          children: [
            Flexible(child: _buildOpenPgnMenuButton(fileName)),
            if (_controller.allGames.isNotEmpty &&
                !_controller.isSolitaireMode &&
                !_singleGameFocus) ...[
              // The collection controls are a second idea, not part of the
              // file button. Give the two enough air that a long filename
              // cannot visually run into the first filter chip.
              const SizedBox(width: 16),
              Expanded(
                child: PgnSliceChips(
                  controller: _controller,
                  onOpenSliceDialog: _openSliceDialog,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (_controller.filteredGames.isNotEmpty) ...[
          // What stays in the bar is the *view modes* — controls with an on
          // state you can see on the board. Everything that merely does
          // something once moved into the overflow below, which is what took
          // this bar from eleven controls to six.
          if (!_controller.isSolitaireMode) ...[
            IconButton(
              onPressed: _controller.toggleOpeningTree,
              icon: Icon(
                Icons.account_tree,
                size: 20,
                color: _controller.showOpeningTree
                    ? Theme.of(context).colorScheme.primary
                    : null,
              ),
              tooltip: actionTooltip(
                'Opening tree',
                shortcut: AppShortcut.toggleOpeningTree,
              ),
            ),
            IconButton(
              // Amend is an inline Game-pane mode. Enabling it from Book
              // would activate an editor that is mounted offstage and give
              // the user no visible way to use it.
              onPressed: _onLineTab ? null : _toggleEditMode,
              icon: Icon(
                _editMode ? Icons.edit : Icons.edit_outlined,
                size: 20,
                color: _editMode ? Theme.of(context).colorScheme.primary : null,
              ),
              tooltip: 'Amend game',
            ),
          ],
          IconButton(
            onPressed: _controller.showOpeningTree
                ? null
                : _toggleSolitaireMode,
            icon: Icon(
              Icons.psychology,
              size: 20,
              color: _controller.isSolitaireMode || _controller.isSolitaireSetup
                  ? Theme.of(context).colorScheme.primary
                  : null,
            ),
            // A disabled control still owes an explanation: without this the
            // opening tree greys the button out and the tooltip goes on
            // advertising a mode that will not open.
            tooltip: _controller.showOpeningTree
                ? 'Solitaire needs one game — close the opening tree first'
                : _controller.isSolitaireMode
                ? 'Leave solitaire (Esc)'
                : _controller.isSolitaireSetup
                ? 'Cancel solitaire setup (Esc)'
                : 'Solitaire — guess the moves of this game (Ctrl+S)',
          ),
          // No group separators: the thin vertical rules read as part of the
          // button beside them ("what is that bar doing on my button?"), and
          // grouping by hairline was never worth that. Icons are spaced and
          // tooltipped instead.
          //
          // "Check this game against my repertoire" used to live here as a
          // fork icon that opened a dialog. It is the Line tab now — the
          // question belongs next to Game and Analysis, not in the toolbar.
          IconButton(
            onPressed: _controller.toggleBoardFlipped,
            icon: const Icon(Icons.swap_vert, size: 20),
            tooltip: 'Flip board (F)',
          ),
          if (!_controller.isSolitaireMode)
            PgnPerspectiveButton(controller: _controller),
        ],
        // One overflow for the whole bar, present in every state — solitaire
        // included, which is how the trophy cabinet and app settings stay
        // reachable there without icons of their own.
        const AppModeSwitcher(),
        const SizedBox(width: 10),
        _buildToolsMenu(),
        IconButton(
          onPressed: () => openAppSettings(context),
          icon: const Icon(Icons.settings_outlined, size: 20),
          tooltip: 'Settings',
        ),
        const SizedBox(width: 4),
      ],
    );
  }

  List<AppMenuEntry> _overflowEntries() {
    final games = _controller.filteredGames;
    final plural = games.length == 1 ? '' : 's';
    return [
      if (games.isNotEmpty && !_controller.isSolitaireMode) ...[
        AppMenuEntry(
          label: 'Edit in Study',
          icon: Icons.edit_note,
          shortcut: 'A',
          onRun: _editInStudy,
        ),
        // Only while the chip bar is hidden — otherwise this duplicates the
        // "Slice" chip sitting in the title row.
        if (_singleGameFocus)
          AppMenuEntry(
            label: 'Filter these games…',
            icon: Icons.filter_alt_outlined,
            onRun: () {
              // Leaving single-game focus is the point of asking for filters:
              // the chip bar comes back with the dialog.
              setState(() => _singleGameFocus = false);
              _openSliceDialog();
            },
          ),
        AppMenuEntry(
          label: 'Export filtered games…',
          icon: Icons.file_upload_outlined,
          dividerAbove: true,
          onRun: _exportSlice,
        ),
        AppMenuEntry(
          label: 'Export as a Scid database…',
          icon: Icons.storage_outlined,
          onRun: _exportSliceAsScid,
          hint:
              'Writes the .si5 / .sg5 / .sn5 trio that Scid 5 opens directly. '
              'Roughly a third the size of the same games as PGN.\n'
              'For Scid vs. PC — a separate fork that predates this format — '
              'export PGN instead and run its own pgnscid on it.',
        ),
        AppMenuEntry(
          label: 'Make a chaptered study from ${games.length} game$plural…',
          icon: Icons.edit_note,
          onRun: () => unawaited(_saveSliceAsStudy()),
          hint:
              'Creates one study and automatically turns every selected game '
              'into a named chapter.',
        ),
        AppMenuEntry(
          label: 'Seed a repertoire from these games…',
          icon: Icons.auto_fix_high,
          onRun: () => unawaited(_generateRepertoireFromGames()),
          hint:
              'Creates a repertoire and hands the ${games.length} currently '
              'filtered game$plural to the Repertoire Builder\n'
              'as the seed for generation. The games become the starting move '
              'data; the builder then explores and scores lines from there.',
        ),
      ],
      // Always listed, even empty: it is how a new user learns that solitaire
      // guesses which beat the game move are collected at all.
      AppMenuEntry(
        label: _controller.totalTrophyCount > 0
            ? 'Solitaire trophies (${_controller.totalTrophyCount})'
            : 'Solitaire trophies',
        icon: Icons.emoji_events,
        dividerAbove: true,
        onRun: _showTrophyCabinet,
        hint: _controller.totalTrophyCount > 0
            ? null
            : 'Guesses that the engine rates above the move actually played, '
                  'found when you analyse a game after solitaire.',
      ),
    ];
  }

  /// Occasional collection actions stay discoverable behind a labelled
  /// control. A bare ellipsis looked like an unexplained settings replacement
  /// and gave no clue what kind of actions were inside it.
  Widget _buildToolsMenu() {
    final entries = _overflowEntries();
    if (entries.isEmpty) return const SizedBox.shrink();
    return PopupMenuButton<int>(
      tooltip: 'Collection tools',
      position: PopupMenuPosition.under,
      onSelected: (i) => entries[i].onRun(),
      itemBuilder: (_) => [
        for (var i = 0; i < entries.length; i++) ...[
          if (entries[i].dividerAbove && i > 0) const PopupMenuDivider(),
          PopupMenuItem<int>(
            value: i,
            enabled: entries[i].enabled,
            child: AppMenuEntryRow(entry: entries[i]),
          ),
        ],
      ],
      child: IgnorePointer(
        child: TextButton.icon(
          onPressed: () {},
          icon: const Icon(Icons.build_outlined, size: 18),
          label: const Text('Tools'),
          style: TextButton.styleFrom(
            foregroundColor: AppColors.ink,
            padding: const EdgeInsets.symmetric(horizontal: 8),
          ),
        ),
      ),
    );
  }

  /// App-bar file button: shows the loaded file name and opens a menu with
  /// recent files, a file browser, paste-from-clipboard, and — once something
  /// is loaded — the way back out to the start screen.
  Widget _buildOpenPgnMenuButton(String fileName) {
    final hasCollection =
        _controller.allGames.isNotEmpty || _controller.filePath != null;
    return PopupMenuButton<String>(
      tooltip: 'Open PGN — recent files, browse, or paste',
      onSelected: (value) {
        if (value == 'browse') {
          unawaited(_pickFile());
        } else if (value == 'paste') {
          unawaited(_pastePgn());
        } else if (value == 'close') {
          _closeFile();
        } else if (value.startsWith('recent:')) {
          _singleGameFocus = false;
          unawaited(_loadFile(value.substring('recent:'.length)));
        }
      },
      onCanceled: _reclaimFocus,
      itemBuilder: (_) => [
        for (final path in _controller.recentFiles)
          PopupMenuItem(
            value: 'recent:$path',
            enabled: path != _controller.filePath,
            child: Tooltip(
              message: path,
              waitDuration: const Duration(milliseconds: 600),
              child: ListTile(
                leading: Icon(
                  path == _controller.filePath
                      ? Icons.check
                      : Icons.description_outlined,
                  size: 20,
                ),
                title: Text(p.basename(path), overflow: TextOverflow.ellipsis),
                dense: true,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
        if (_controller.recentFiles.isNotEmpty) const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'browse',
          child: ListTile(
            leading: Icon(Icons.folder_open, size: 20),
            title: Text('Browse for file…'),
            dense: true,
            contentPadding: EdgeInsets.zero,
          ),
        ),
        const PopupMenuItem(
          value: 'paste',
          child: ListTile(
            leading: Icon(Icons.content_paste, size: 20),
            title: Text('Paste PGN from clipboard (Ctrl+V)'),
            dense: true,
            contentPadding: EdgeInsets.zero,
          ),
        ),
        // The way back out. Without it the viewer has no "nothing open" state
        // once a file has been opened — every route through this menu swaps
        // one collection for another.
        if (hasCollection) ...[
          const PopupMenuDivider(),
          const PopupMenuItem(
            value: 'close',
            child: ListTile(
              leading: Icon(Icons.close, size: 20),
              title: Text('Close file — back to the start screen'),
              dense: true,
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ],
      ],
      // IgnorePointer lets the PopupMenuButton's own tap region handle the
      // click while keeping the outlined-button look.
      child: IgnorePointer(
        child: OutlinedButton.icon(
          onPressed: () {},
          icon: const Icon(Icons.folder_open, size: 18),
          label: Text(
            fileName.isEmpty ? 'Open PGN' : fileName,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }
}
