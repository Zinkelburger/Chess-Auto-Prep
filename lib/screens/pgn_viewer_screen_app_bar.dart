// App-bar builders for the PGN viewer: title row with the open-PGN menu and
// slice chips, plus the study-mode / board-view / file action groups.
// Part of pgn_viewer_screen.dart.
part of 'pgn_viewer_screen.dart';

/// App-bar builders, split out of [_PgnViewerScreenState]. Depends on
/// [_RepertoireGenerationMixin] for the overflow menu's generate action.
mixin _AppBarBuildersMixin
    on State<PgnViewerScreen>, _RepertoireGenerationMixin {
  bool get _editMode;

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
  Future<void> _pickFile();
  Future<void> _pastePgn();
  Future<void> _loadFile(String path);
  void _closeFile();
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
            const Text('PGN Viewer'),
            const SizedBox(width: 12),
            Flexible(child: _buildOpenPgnMenuButton(fileName)),
            if (_controller.allGames.isNotEmpty &&
                !_controller.isSolitaireMode &&
                !_singleGameFocus) ...[
              const SizedBox(width: 8),
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
          // Study modes: opening tree, amend, solitaire.
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
              onPressed: _toggleEditMode,
              icon: Icon(
                _editMode ? Icons.edit : Icons.edit_outlined,
                size: 20,
                color: _editMode ? Theme.of(context).colorScheme.primary : null,
              ),
              tooltip: 'Amend game',
            ),
            IconButton(
              onPressed: _editInStudy,
              icon: const Icon(Icons.edit_note, size: 20),
              tooltip: 'Edit in Study (A)',
            ),
          ],
          IconButton(
            onPressed: _controller.showOpeningTree
                ? null
                : _controller.toggleSolitaire,
            icon: Icon(
              Icons.psychology,
              size: 20,
              color: _controller.isSolitaireMode
                  ? Theme.of(context).colorScheme.primary
                  : null,
            ),
            tooltip: _controller.isSolitaireMode
                ? 'Exit solitaire mode (Esc)'
                : 'Solitaire mode (Ctrl+S)',
          ),
          if (_controller.isSolitaireMode && _controller.totalTrophyCount > 0)
            IconButton(
              onPressed: () => _showTrophyCabinet(),
              icon: const Icon(
                Icons.emoji_events,
                size: 20,
                color: AppColors.starAccent,
              ),
              tooltip: 'Trophies (${_controller.totalTrophyCount})',
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
          if (!_controller.isSolitaireMode) ...[
            PgnPerspectiveButton(controller: _controller),
            // File / misc: export, overflow.
            IconButton(
              onPressed: _exportSlice,
              icon: const Icon(Icons.file_upload_outlined, size: 20),
              tooltip: 'Export filtered games',
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, size: 20),
              tooltip: 'More actions',
              onSelected: (value) {
                if (value == 'generate_repertoire') {
                  unawaited(_generateRepertoireFromGames());
                } else if (value == 'save_as_study') {
                  unawaited(_saveSliceAsStudy());
                } else if (value == 'trophies') {
                  _showTrophyCabinet();
                } else if (value == 'slice') {
                  // Leaving single-game focus is the point of asking for
                  // filters: the chip bar comes back with the dialog.
                  setState(() => _singleGameFocus = false);
                  _openSliceDialog();
                }
              },
              itemBuilder: (_) => [
                // Only while the chip bar is hidden — otherwise this duplicates
                // the "Slice" chip sitting in the title row.
                if (_singleGameFocus)
                  const PopupMenuItem(
                    value: 'slice',
                    child: ListTile(
                      leading: Icon(Icons.filter_alt_outlined, size: 20),
                      title: Text('Filter these games…'),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                PopupMenuItem(
                  value: 'save_as_study',
                  child: ListTile(
                    leading: const Icon(Icons.edit_note, size: 20),
                    title: Text(
                      'Save ${_controller.filteredGames.length} filtered '
                      'game${_controller.filteredGames.length == 1 ? '' : 's'} '
                      'as study…',
                    ),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                PopupMenuItem(
                  value: 'generate_repertoire',
                  child: ListTile(
                    leading: const Icon(Icons.auto_fix_high, size: 20),
                    title: const Text('Seed a repertoire from these games…'),
                    trailing: InfoHint(
                      'Creates a repertoire and hands the '
                      '${_controller.filteredGames.length} currently filtered '
                      'game${_controller.filteredGames.length == 1 ? '' : 's'} '
                      'to the Repertoire Builder\n'
                      'as the seed for generation. The games become the '
                      'starting move data; the builder then explores and '
                      'scores lines from there.',
                    ),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                PopupMenuItem(
                  value: 'trophies',
                  child: ListTile(
                    leading: const Icon(
                      Icons.emoji_events,
                      size: 20,
                      color: AppColors.starAccent,
                    ),
                    title: Text(
                      'Trophy cabinet (${_controller.totalTrophyCount})',
                    ),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ],
            ),
          ],
        ],
        const AppSettingsButton(),
        const AppModeMenuButton(),
      ],
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
