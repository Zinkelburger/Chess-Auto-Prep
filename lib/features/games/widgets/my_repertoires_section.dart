import 'package:flutter/material.dart';

import '../../../widgets/settings/settings_widgets.dart';
import 'my_repertoires_panel.dart';

/// Settings → My repertoires: designate which repertoire folders are the
/// books you actually play as White and as Black. The recent-games home
/// checks every game against them to show where you left prep.
///
/// The controls themselves live in [MyRepertoiresPanel] so the same UI can be
/// opened straight from the home pane, where the deviation column that depends
/// on it is visible.
class MyRepertoiresSection extends StatelessWidget {
  const MyRepertoiresSection({super.key});

  @override
  Widget build(BuildContext context) {
    return const SettingsGroup(
      title: 'My repertoires',
      icon: Icons.fork_right,
      subtitle:
          'Compare your games with these books to see where you left your prep.',
      children: [
        Padding(padding: EdgeInsets.all(20), child: MyRepertoiresPanel()),
      ],
    );
  }
}
