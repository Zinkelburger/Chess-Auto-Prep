import 'dart:async';
import 'package:flutter/material.dart';
import 'package:chess_auto_prep/design_system/theme/app_theme.dart';
import 'package:chess_auto_prep/features/documents/controllers/document_save_session.dart';
import 'package:chess_auto_prep/features/documents/models/document_save_state.dart';
import 'package:chess_auto_prep/features/documents/widgets/document_save_panel.dart';
import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';

/// Minimal editor harness; all save behavior and controls come from production.
class DocumentSaveHost extends StatefulWidget {
  const DocumentSaveHost({
    super.key,
    required this.session,
    required this.chooseCopyDestination,
    this.scale = 1,
    this.light = false,
  });
  final DocumentSaveSession session;
  final Future<String?> Function(BuildContext) chooseCopyDestination;
  final double scale;
  final bool light;
  @override
  State<DocumentSaveHost> createState() => _DocumentSaveHostState();
}

class _DocumentSaveHostState extends State<DocumentSaveHost> {
  late final editor = TextEditingController(text: widget.session.state.content);
  final focus = FocusNode();
  StreamSubscription<DocumentSaveState>? subscription;
  @override
  void initState() {
    super.initState();
    subscription = widget.session.changes.listen((state) {
      if (editor.text != state.content) editor.text = state.content;
    });
  }

  @override
  void dispose() {
    unawaited(subscription?.cancel());
    editor.dispose();
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: widget.light ? AppTheme.light() : AppTheme.dark(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(widget.scale)),
      child: child!,
    ),
    home: Scaffold(
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              TextField(
                key: const ValueKey('document-draft'),
                controller: editor,
                focusNode: focus,
                minLines: 3,
                maxLines: 6,
                onChanged: widget.session.edit,
              ),
              DocumentSavePanel(
                session: widget.session,
                chooseCopyDestination: widget.chooseCopyDestination,
                focusEditor: focus.requestFocus,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
