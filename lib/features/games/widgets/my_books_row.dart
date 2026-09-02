import 'dart:async';

import 'package:flutter/material.dart';

import '../../../theme/app_text_styles.dart';
import '../services/my_repertoire_settings.dart';
import 'my_repertoires_panel.dart';

/// Which repertoires the games are checked against, and the way to change
/// them — one muted line in the home column's footer, next to the accounts
/// the games come from.
class MyBooksRow extends StatefulWidget {
  const MyBooksRow({super.key});

  @override
  State<MyBooksRow> createState() => _MyBooksRowState();
}

class _MyBooksRowState extends State<MyBooksRow> {
  final _settings = MyRepertoireSettings.instance;

  @override
  void initState() {
    super.initState();
    unawaited(_settings.ensureLoaded());
  }

  static String _summary(List<String> paths) {
    if (paths.isEmpty) return 'not set';
    final names = [for (final p in paths) p.split(RegExp(r'[/\\]')).last];
    if (names.length <= 2) return names.join(', ');
    return '${names.take(2).join(', ')} +${names.length - 2}';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _settings,
      builder: (context, _) {
        final white = _settings.whitePaths;
        final black = _settings.blackPaths;
        return Row(
          children: [
            Expanded(
              child: Text(
                'Books — White: ${_summary(white)} · '
                'Black: ${_summary(black)}',
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.muted,
              ),
            ),
            TextButton(
              onPressed: () => showMyRepertoiresDialog(context),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('Change'),
            ),
          ],
        );
      },
    );
  }
}
