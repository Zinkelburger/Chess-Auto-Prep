import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../../theme/app_text_styles.dart';

/// Database selection lives in the workspace so the board stays available.
class PgnDatabasePicker extends StatefulWidget {
  const PgnDatabasePicker({
    super.key,
    required this.recent,
    required this.onSelected,
    required this.onCollection,
  });
  final List<String> recent;
  final ValueChanged<String> onSelected;
  final VoidCallback onCollection;
  @override
  State<PgnDatabasePicker> createState() => _PgnDatabasePickerState();
}

class _PgnDatabasePickerState extends State<PgnDatabasePicker> {
  final _search = TextEditingController();
  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _browse() async {
    final result = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['pgn'],
    );
    if (!mounted || result == null || result.path == null) return;
    widget.onSelected(result.path!);
  }

  @override
  Widget build(BuildContext context) {
    final query = _search.text.toLowerCase();
    final files = widget.recent
        .where((path) => path.toLowerCase().contains(query))
        .toList();
    return Padding(
      padding: const EdgeInsets.all(16),
      child: SizedBox(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Database', style: AppTextStyles.title),
            const SizedBox(height: 8),
            const Text(
              'Choose a PGN database to find games matching the position on your board.',
              style: AppTextStyles.muted,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                FilledButton.icon(
                  onPressed: _browse,
                  icon: const Icon(Icons.folder_open, size: 18),
                  label: const Text('Open PGN database…'),
                ),
                TextButton(
                  onPressed: widget.onCollection,
                  child: const Text('Organize or export this collection'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _search,
              autofocus: true,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search recent files',
              ),
              onChanged: (_) {
                if (mounted) setState(() {});
              },
            ),
            const SizedBox(height: 8),
            Expanded(
              child: files.isEmpty
                  ? const Center(
                      child: Text(
                        'No recent files match',
                        style: AppTextStyles.muted,
                      ),
                    )
                  : ListView.builder(
                      itemCount: files.length,
                      itemBuilder: (_, i) => ListTile(
                        dense: true,
                        leading: const Icon(
                          Icons.description_outlined,
                          size: 18,
                        ),
                        title: Text(
                          p.basename(files[i]),
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          p.dirname(files[i]),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => widget.onSelected(files[i]),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
