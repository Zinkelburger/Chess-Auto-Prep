import 'dart:async';

import 'package:flutter/material.dart';

import '../../../theme/app_text_styles.dart';
import '../../../widgets/common/home_block.dart';
import '../services/my_repertoire_settings.dart';
import 'my_repertoires_panel.dart';

/// Which repertoires the games are checked against: the Books block of the
/// tactics home column, one row per colour, with the way to change them in
/// the block's corner like every other block's one action.
class MyBooksBlock extends StatefulWidget {
  const MyBooksBlock({super.key});

  @override
  State<MyBooksBlock> createState() => _MyBooksBlockState();
}

class _MyBooksBlockState extends State<MyBooksBlock> {
  final _settings = MyRepertoireSettings.instance;

  @override
  void initState() {
    super.initState();
    unawaited(_settings.ensureLoaded());
  }

  /// File names, the first two spelled out and the rest counted.
  static String summary(List<String> paths) {
    final names = [for (final p in paths) p.split(RegExp(r'[/\\]')).last];
    if (names.length <= 2) return names.join(', ');
    return '${names.take(2).join(', ')} +${names.length - 2}';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _settings,
      builder: (context, _) {
        return HomeBlock(
          heading: 'Books',
          trailing: HomeBlockAction(
            label: 'Change…',
            onPressed: () => showMyRepertoiresDialog(context),
          ),
          children: [
            _BookRow(colour: 'White', paths: _settings.whitePaths),
            _BookRow(colour: 'Black', paths: _settings.blackPaths),
          ],
        );
      },
    );
  }
}

/// One colour's books. A set book is a value in body-strong ink; "Not set"
/// is muted, because it is the absence of one.
class _BookRow extends StatelessWidget {
  const _BookRow({required this.colour, required this.paths});

  final String colour;
  final List<String> paths;

  @override
  Widget build(BuildContext context) {
    return HomeBlockRow(
      label: colour,
      child: Text(
        paths.isEmpty ? 'Not set' : _MyBooksBlockState.summary(paths),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: paths.isEmpty ? AppTextStyles.muted : AppTextStyles.bodyStrong,
      ),
    );
  }
}
