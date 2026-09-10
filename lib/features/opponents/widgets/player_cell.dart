import 'dart:async';

import 'package:flutter/material.dart';

import '../../../theme/app_text_styles.dart';

/// A cell stays mounted while typing; each edit is persisted in order.
class PlayerCell extends StatefulWidget {
  const PlayerCell({
    super.key,
    required this.value,
    required this.label,
    required this.save,
    this.validate,
    this.autofocus = false,
  });
  final String value;
  final String label;
  final Future<void> Function(String) save;
  final String? Function(String)? validate;
  final bool autofocus;

  @override
  State<PlayerCell> createState() => _PlayerCellState();
}

class _PlayerCellState extends State<PlayerCell> {
  late final _text = TextEditingController(text: widget.value);
  final _focus = FocusNode();
  String? _error;
  int _revision = 0;
  bool _saving = false;

  @override
  void didUpdateWidget(PlayerCell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_focus.hasFocus &&
        !_saving &&
        _error == null &&
        widget.value != oldWidget.value) {
      _text.text = widget.value;
    }
  }

  Future<void> _save(String value) async {
    final revision = ++_revision;
    final error = widget.validate?.call(value.trim());
    if (!mounted) return;
    setState(() {
      _error = error;
      _saving = error == null;
    });
    if (error != null) return;
    try {
      await widget.save(value.trim());
      if (mounted && revision == _revision) setState(() => _saving = false);
    } catch (_) {
      if (mounted && revision == _revision) {
        setState(() {
          _saving = false;
          _error = 'Not saved. Press Enter to retry.';
        });
      }
    }
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: _text,
    focusNode: _focus,
    autofocus: widget.autofocus,
    style: AppTextStyles.body,
    minLines: 1,
    maxLines: ['Name', 'Chess.com', 'Lichess', 'Notes'].contains(widget.label)
        ? 3
        : 1,
    textInputAction: TextInputAction.done,
    decoration: InputDecoration(
      hintText: widget.label,
      filled: true,
      fillColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
      border: const OutlineInputBorder(),
      errorText: _error,
      errorMaxLines: 2,
      suffixIcon: _saving
          ? const Padding(
              padding: EdgeInsets.all(12),
              child: SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          : null,
    ),
    onChanged: (value) => unawaited(_save(value)),
    onSubmitted: (value) => unawaited(_save(value)),
  );
}
