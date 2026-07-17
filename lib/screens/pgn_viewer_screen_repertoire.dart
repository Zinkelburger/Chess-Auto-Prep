// Generate-repertoire-from-games flow for the PGN viewer: name prompt,
// duplicate-name resolution, raw-games sidecar write, and the handoff to the
// repertoire builder. Part of pgn_viewer_screen.dart.
part of 'pgn_viewer_screen.dart';

enum _DuplicateNameAction { useExisting, rename, cancel }

/// Generate-repertoire-from-games flow, split out of [_PgnViewerScreenState].
mixin _RepertoireGenerationMixin on State<PgnViewerScreen> {
  PgnViewerController get _controller;
  void _reclaimFocus();

  Future<void> _generateRepertoireFromGames() async {
    if (_controller.filteredGames.isEmpty) return;

    final storage = StorageFactory.instance;
    var suggestedName = _suggestRepertoireName();

    // Loop: show name dialog → check collision → resolve or retry.
    while (true) {
      final result = await showGenerateRepertoireDialog(
        context,
        suggestedName: suggestedName,
      );
      if (result == null || !mounted) {
        _reclaimFocus();
        return;
      }

      final safeName = result.name
          .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
          .replaceAll(RegExp(r'_+'), '_')
          .trim();
      if (safeName.isEmpty) {
        showAppSnackBar(context, 'Invalid repertoire name.', isError: true);
        _reclaimFocus();
        return;
      }

      try {
        final repertoirePath = await storage.repertoireFilePath(safeName);

        if (await storage.fileExists(repertoirePath)) {
          if (!mounted) return;
          final action = await _showDuplicateNameDialog(safeName);
          if (!mounted) return;

          switch (action) {
            case _DuplicateNameAction.useExisting:
              await _seedExistingRepertoire(
                storage: storage,
                safeName: safeName,
                repertoirePath: repertoirePath,
              );
              _reclaimFocus();
              return;
            case _DuplicateNameAction.rename:
              suggestedName = safeName;
              continue; // re-show name dialog
            case _DuplicateNameAction.cancel:
            case null:
              _reclaimFocus();
              return;
          }
        }

        // New repertoire — write files and switch.
        final rawGamesName = '${safeName}_raw_games';
        final rawGamesPath = await storage.repertoireFilePath(rawGamesName);
        await storage.writeFile(rawGamesPath, _controller.buildExportContent());

        final header =
            '// $safeName Repertoire\n'
            '// Color: ${result.color}\n'
            '// Created on ${DateTime.now().toString().split('.')[0]}\n\n';
        await storage.writeFile(repertoirePath, header);

        if (!mounted) return;
        final gameCount = _controller.filteredGames.length;
        showAppSnackBar(
          context,
          'Created "$safeName" — switching to builder with $gameCount games.',
        );

        context.read<AppState>().switchToBuilderWithGeneration(
          repertoirePath: repertoirePath,
          pgnPaths: [rawGamesPath],
        );
        _reclaimFocus();
        return;
      } catch (e) {
        debugPrint('Generate repertoire from games failed: $e');
        if (mounted) {
          showAppSnackBar(
            context,
            'Failed to create repertoire.',
            isError: true,
          );
        }
        _reclaimFocus();
        return;
      }
    }
  }

  /// Overwrite the raw-games sidecar and open the existing repertoire in
  /// DB Explorer mode with auto-start.
  Future<void> _seedExistingRepertoire({
    required dynamic storage,
    required String safeName,
    required String repertoirePath,
  }) async {
    final rawGamesName = '${safeName}_raw_games';
    final rawGamesPath = await storage.repertoireFilePath(rawGamesName);
    await storage.writeFile(rawGamesPath, _controller.buildExportContent());

    if (!mounted) return;
    final gameCount = _controller.filteredGames.length;
    showAppSnackBar(
      context,
      'Updated seed for "$safeName" — switching to builder with $gameCount games.',
    );

    context.read<AppState>().switchToBuilderWithGeneration(
      repertoirePath: repertoirePath,
      pgnPaths: [rawGamesPath],
    );
  }

  Future<_DuplicateNameAction?> _showDuplicateNameDialog(String name) {
    return showDialog<_DuplicateNameAction>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Repertoire Already Exists'),
        content: Text(
          '"$name" already exists. You can update its game data '
          'and re-run generation, or pick a different name.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, _DuplicateNameAction.cancel),
            child: const Text('Cancel'),
          ),
          OutlinedButton(
            onPressed: () => Navigator.pop(ctx, _DuplicateNameAction.rename),
            child: const Text('Pick Different Name'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(ctx, _DuplicateNameAction.useExisting),
            child: const Text('Use Existing & Re-seed'),
          ),
        ],
      ),
    );
  }

  String _suggestRepertoireName() {
    final config = _controller.activeSliceConfig;
    final parts = <String>[];

    for (final filter in config.headerFilters) {
      if (filter.value.isNotEmpty &&
          (filter.field == 'White' || filter.field == 'Black')) {
        parts.add(filter.value);
      }
    }

    if (parts.isEmpty && _controller.filePath != null) {
      parts.add(p.basenameWithoutExtension(_controller.filePath!));
    }

    return parts.isEmpty ? 'My Repertoire' : parts.join(' ');
  }
}
