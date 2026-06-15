/// Compact, embeddable multi-source PGN attachment panel.
///
/// Replaces the oversized bottom-sheet import dialog with a compact list
/// of PGN sources, each with its own name, color, file reference, slice
/// config, and remove button. Supports adding via file picker or compact paste.
library;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/board_preview_controller.dart';
import '../models/pgn_filter_models.dart';
import '../models/pgn_source.dart';
import '../services/pgn_parsing_service.dart' as pgn;
import '../services/storage/storage_factory.dart';
import 'pgn_inline_slice_editor.dart';

/// Compact panel for managing multiple PGN sources with per-source slicing.
class PgnSourcesPanel extends StatefulWidget {
  /// Pre-loaded sources (e.g. from a previous session).
  final List<PgnSource>? initialSources;

  /// Called whenever the sources list changes.
  final ValueChanged<List<PgnSource>>? onSourcesChanged;

  /// Board preview controller (for slice preview hover).
  final BoardPreviewController? boardPreview;

  /// Current board FEN for position filter chip.
  final String? currentFen;

  const PgnSourcesPanel({
    super.key,
    this.initialSources,
    this.onSourcesChanged,
    this.boardPreview,
    this.currentFen,
  });

  @override
  State<PgnSourcesPanel> createState() => PgnSourcesPanelState();
}

class PgnSourcesPanelState extends State<PgnSourcesPanel> {
  final List<PgnSource> _sources = [];
  String? _expandedSourceId;

  /// Access current sources externally.
  List<PgnSource> get sources => List.unmodifiable(_sources);

  @override
  void initState() {
    super.initState();
    if (widget.initialSources != null) {
      _sources.addAll(widget.initialSources!);
    }
  }

  /// Programmatically seed sources (e.g. from file paths).
  void seedSources(List<PgnSource> sources) {
    setState(() {
      _sources
        ..clear()
        ..addAll(sources);
    });
    _notify();
  }

  void _notify() {
    widget.onSourcesChanged?.call(List.unmodifiable(_sources));
  }

  Future<void> _addFromFile() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pgn', 'txt'],
        allowMultiple: true,
        withData: false,
        withReadStream: false,
      );
      if (result == null || result.files.isEmpty) return;

      for (final file in result.files) {
        final path = file.path;
        if (path == null) continue;
        // Dedupe by path
        if (_sources.any((s) => s.filePath == path)) continue;

        final content = await StorageFactory.instance.readFile(path);
        final gameCount = content != null ? pgn.countPgnGames(content) : 0;

        final source = PgnSource(
          id: PgnSource.generateId(),
          name: p.basenameWithoutExtension(path),
          filePath: path,
          rawPgnContent: content,
          totalGames: gameCount,
        );
        setState(() => _sources.add(source));
      }
      _notify();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error picking file: $e')),
        );
      }
    }
  }

  void _showPasteDialog() {
    showDialog<PgnSource>(
      context: context,
      builder: (ctx) => _CompactPasteDialog(),
    ).then((source) {
      if (source != null) {
        setState(() => _sources.add(source));
        _notify();
      }
    });
  }

  void _removeSource(int index) {
    final id = _sources[index].id;
    setState(() {
      _sources.removeAt(index);
      if (_expandedSourceId == id) _expandedSourceId = null;
    });
    _notify();
  }

  void _toggleSliceEditor(String id) {
    setState(() {
      _expandedSourceId = _expandedSourceId == id ? null : id;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header
        Row(
          children: [
            Icon(Icons.library_books, size: 16, color: cs.primary),
            const SizedBox(width: 8),
            Text(
              'PGN Sources',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: cs.onSurface,
              ),
            ),
            const Spacer(),
            _AddPgnButton(
              onPickFile: _addFromFile,
              onPaste: _showPasteDialog,
            ),
          ],
        ),
        const SizedBox(height: 8),

        // Source list
        if (_sources.isEmpty)
          _EmptyState(
            onPickFile: _addFromFile,
            onPaste: _showPasteDialog,
          )
        else
          ..._sources.asMap().entries.map((entry) {
            final idx = entry.key;
            final source = entry.value;
            final isExpanded = _expandedSourceId == source.id;
            return _SourceRow(
              source: source,
              index: idx,
              isExpanded: isExpanded,
              boardPreview: widget.boardPreview,
              currentFen: widget.currentFen,
              onRemove: () => _removeSource(idx),
              onToggleSlice: () => _toggleSliceEditor(source.id),
              onSliceResult: (indices, config) {
                setState(() {
                  source.sliceConfig = config;
                  source.matchedIndices = indices;
                });
                _notify();
              },
            );
          }),
      ],
    );
  }
}

// ── Add PGN button (dropdown) ──

class _AddPgnButton extends StatelessWidget {
  final VoidCallback onPickFile;
  final VoidCallback onPaste;

  const _AddPgnButton({required this.onPickFile, required this.onPaste});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return PopupMenuButton<String>(
      onSelected: (v) {
        if (v == 'file') onPickFile();
        if (v == 'paste') onPaste();
      },
      offset: const Offset(0, 32),
      itemBuilder: (ctx) => [
        PopupMenuItem(
          value: 'file',
          height: 36,
          child: Row(
            children: [
              Icon(Icons.file_open, size: 16, color: cs.onSurface),
              const SizedBox(width: 8),
              const Text('Pick .pgn file', style: TextStyle(fontSize: 12)),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'paste',
          height: 36,
          child: Row(
            children: [
              Icon(Icons.paste, size: 16, color: cs.onSurface),
              const SizedBox(width: 8),
              const Text('Paste PGN', style: TextStyle(fontSize: 12)),
            ],
          ),
        ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: cs.primaryContainer,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.add, size: 14, color: cs.onPrimaryContainer),
            const SizedBox(width: 4),
            Text(
              'Add PGN',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: cs.onPrimaryContainer,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Source row ──

class _SourceRow extends StatelessWidget {
  final PgnSource source;
  final int index;
  final bool isExpanded;
  final BoardPreviewController? boardPreview;
  final String? currentFen;
  final VoidCallback onRemove;
  final VoidCallback onToggleSlice;
  final SliceResultCallback onSliceResult;

  const _SourceRow({
    required this.source,
    required this.index,
    required this.isExpanded,
    this.boardPreview,
    this.currentFen,
    required this.onRemove,
    required this.onToggleSlice,
    required this.onSliceResult,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: isExpanded
                  ? const BorderRadius.vertical(top: Radius.circular(8))
                  : BorderRadius.circular(8),
              border:
                  Border.all(color: cs.outlineVariant.withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                // Color badge
                Container(
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(
                    color: source.color == PgnSourceColor.white
                        ? Colors.white
                        : Colors.grey[900],
                    borderRadius: BorderRadius.circular(3),
                    border: Border.all(color: Colors.grey[600]!, width: 0.5),
                  ),
                  child: Center(
                    child: Text(
                      source.color == PgnSourceColor.white ? '♔' : '♚',
                      style: TextStyle(
                        fontSize: 11,
                        color: source.color == PgnSourceColor.white
                            ? Colors.grey[900]
                            : Colors.white,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Name
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        source.name,
                        style: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w500),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (source.filePath != null)
                        Text(
                          p.basename(source.filePath!),
                          style: TextStyle(
                              fontSize: 10, color: cs.onSurfaceVariant),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                // Slice chip
                GestureDetector(
                  onTap: onToggleSlice,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: source.isSliced
                          ? cs.tertiaryContainer
                          : cs.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: source.isSliced
                            ? cs.tertiary.withValues(alpha: 0.5)
                            : cs.outlineVariant,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          source.isSliced
                              ? Icons.content_cut
                              : Icons.select_all,
                          size: 12,
                          color: source.isSliced
                              ? cs.onTertiaryContainer
                              : cs.onSurfaceVariant,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          source.sliceLabel,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: source.isSliced
                                ? FontWeight.w600
                                : FontWeight.normal,
                            color: source.isSliced
                                ? cs.onTertiaryContainer
                                : cs.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(width: 2),
                        Icon(
                          isExpanded ? Icons.expand_less : Icons.expand_more,
                          size: 12,
                          color: cs.onSurfaceVariant,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                // Game count
                Text(
                  '${source.totalGames}',
                  style: TextStyle(
                    fontSize: 10,
                    color: cs.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 4),
                // Remove
                SizedBox(
                  width: 24,
                  height: 24,
                  child: IconButton(
                    icon: Icon(Icons.close, size: 14, color: cs.error),
                    padding: EdgeInsets.zero,
                    onPressed: onRemove,
                    tooltip: 'Remove source',
                  ),
                ),
              ],
            ),
          ),
          // Expanded slice editor
          if (isExpanded && source.rawPgnContent != null)
            _buildSliceEditor(context),
        ],
      ),
    );
  }

  Widget _buildSliceEditor(BuildContext context) {
    final games = _parseGames(source.rawPgnContent!);
    return InlineSliceEditor(
      allGames: games,
      initialConfig: source.sliceConfig,
      currentFen: currentFen,
      boardPreview: boardPreview,
      ownerTag: source.id,
      onResult: onSliceResult,
    );
  }

  List<GameRecord> _parseGames(String content) {
    final chunks = pgn.splitPgnIntoGames(content);
    return chunks.map((chunk) {
      final headers = pgn.extractHeaders(chunk);
      return (headers: headers, pgnText: chunk);
    }).toList();
  }
}

// ── Empty state ──

class _EmptyState extends StatelessWidget {
  final VoidCallback onPickFile;
  final VoidCallback onPaste;

  const _EmptyState({required this.onPickFile, required this.onPaste});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
      decoration: BoxDecoration(
        border: Border.all(
          color: cs.outlineVariant.withValues(alpha: 0.4),
          style: BorderStyle.solid,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.upload_file, size: 32, color: cs.onSurfaceVariant),
          const SizedBox(height: 8),
          Text(
            'No PGN sources added',
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: onPickFile,
                icon: const Icon(Icons.file_open, size: 14),
                label: const Text('Pick file', style: TextStyle(fontSize: 11)),
                style: OutlinedButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                ),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: onPaste,
                icon: const Icon(Icons.paste, size: 14),
                label: const Text('Paste PGN', style: TextStyle(fontSize: 11)),
                style: OutlinedButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Compact paste dialog ──

class _CompactPasteDialog extends StatefulWidget {
  @override
  State<_CompactPasteDialog> createState() => _CompactPasteDialogState();
}

class _CompactPasteDialogState extends State<_CompactPasteDialog> {
  final _controller = TextEditingController();
  final _nameController = TextEditingController(text: 'Pasted PGN');
  int _gameCount = 0;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    _nameController.dispose();
    super.dispose();
  }

  void _recount() {
    final text = _controller.text.trim();
    if (text.isEmpty) {
      setState(() {
        _gameCount = 0;
        _error = null;
      });
      return;
    }
    try {
      final count = pgn.countPgnGames(text);
      setState(() {
        _gameCount = count;
        _error = count == 0 ? 'No valid lines found.' : null;
      });
    } catch (e) {
      setState(() {
        _gameCount = 0;
        _error = 'Parse error: $e';
      });
    }
  }

  void _confirm() {
    final text = _controller.text.trim();
    if (text.isEmpty || _gameCount == 0) return;

    final source = PgnSource(
      id: PgnSource.generateId(),
      name: _nameController.text.trim().isEmpty
          ? 'Pasted PGN'
          : _nameController.text.trim(),
      rawPgnContent: text,
      totalGames: _gameCount,
    );
    Navigator.of(context).pop(source);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return AlertDialog(
      title: const Text('Paste PGN', style: TextStyle(fontSize: 16)),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Name',
                isDense: true,
                border: OutlineInputBorder(),
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              ),
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _controller,
              maxLines: 6,
              minLines: 3,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: InputDecoration(
                hintText:
                    '[Event "Opening"]\n[Result "*"]\n\n1. e4 e5 2. Nf3 *',
                hintStyle: TextStyle(
                    color: cs.onSurfaceVariant.withValues(alpha: 0.4),
                    fontFamily: 'monospace',
                    fontSize: 12),
                border: const OutlineInputBorder(),
                contentPadding: const EdgeInsets.all(10),
              ),
              onChanged: (_) => _recount(),
            ),
            const SizedBox(height: 8),
            if (_error != null)
              Row(
                children: [
                  Icon(Icons.warning_amber, size: 14, color: cs.error),
                  const SizedBox(width: 6),
                  Text(_error!,
                      style: TextStyle(fontSize: 11, color: cs.error)),
                ],
              )
            else if (_gameCount > 0)
              Row(
                children: [
                  Icon(Icons.check_circle_outline, size: 14, color: cs.primary),
                  const SizedBox(width: 6),
                  Text(
                    '$_gameCount line${_gameCount == 1 ? '' : 's'} found',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: cs.primary),
                  ),
                ],
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _gameCount > 0 ? _confirm : null,
          child: const Text('Add'),
        ),
      ],
    );
  }
}
