/// Repertoire selection screen
/// Full-screen push that wraps [RepertoireListBody] with its own Scaffold.
library;

import 'package:flutter/material.dart';

import '../widgets/repertoire_list_body.dart';

class RepertoireSelectionScreen extends StatelessWidget {
  const RepertoireSelectionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text('Select Repertoire'),
        actions: [
          IconButton(
            tooltip: 'Back',
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.arrow_back),
          ),
        ],
      ),
      body: RepertoireListBody(
        onSelected: (repertoire) => Navigator.of(context).pop(repertoire),
      ),
    );
  }
}
