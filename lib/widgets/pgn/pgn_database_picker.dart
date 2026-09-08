import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../../theme/app_text_styles.dart';

Future<String?> showPgnDatabasePicker(
  BuildContext context,
  List<String> recent,
) => showDialog<String>(
  context: context,
  builder: (_) => _DatabasePicker(recent: recent),
);

class _DatabasePicker extends StatefulWidget {
  const _DatabasePicker({required this.recent});
  final List<String> recent;
  @override
  State<_DatabasePicker> createState() => _DatabasePickerState();
}

class _DatabasePickerState extends State<_DatabasePicker> {
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
    Navigator.pop(context, result.path);
  }

  @override
  Widget build(BuildContext context) {
    final query = _search.text.toLowerCase();
    final files = widget.recent
        .where((path) => path.toLowerCase().contains(query))
        .toList();
    return AlertDialog(
      title: const Text('Check against database'),
      content: SizedBox(
        width: 480,
        height: 320,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Open a PGN database in a tab. Matching games follow the position on your board.',
              style: AppTextStyles.muted,
            ),
            const SizedBox(height: 16),
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
                        onTap: () => Navigator.pop(context, files[i]),
                      ),
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton.icon(
          onPressed: _browse,
          icon: const Icon(Icons.folder_open),
          label: const Text('Open PGN file…'),
        ),
      ],
    );
  }
}
