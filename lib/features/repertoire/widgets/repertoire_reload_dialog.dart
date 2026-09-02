/// The "check disk for changes" window.
///
/// Opens on a spinner, re-reads the repertoire file, and then stays open on a
/// summary of what the file gained or lost. The summary is the point: without
/// it a reload is indistinguishable from doing nothing, so nobody presses it.
library;

import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import '../models/repertoire_reload_summary.dart';

/// Runs [reload] behind a modal and shows what it found.
///
/// The dialog is not dismissible by tapping outside: the result is the whole
/// reason the button exists, and a stray click on the board behind it would
/// throw the answer away before it is read.
Future<void> showRepertoireReloadDialog(
  BuildContext context, {
  required Future<RepertoireReloadSummary> Function() reload,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _RepertoireReloadDialog(reload: reload),
  );
}

class _RepertoireReloadDialog extends StatefulWidget {
  const _RepertoireReloadDialog({required this.reload});

  final Future<RepertoireReloadSummary> Function() reload;

  @override
  State<_RepertoireReloadDialog> createState() =>
      _RepertoireReloadDialogState();
}

class _RepertoireReloadDialogState extends State<_RepertoireReloadDialog> {
  RepertoireReloadSummary? _summary;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    RepertoireReloadSummary summary;
    try {
      summary = await widget.reload();
    } catch (e) {
      summary = RepertoireReloadSummary.failed('$e');
    }
    if (mounted) setState(() => _summary = summary);
  }

  @override
  Widget build(BuildContext context) {
    final summary = _summary;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 620),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(
              title: summary == null
                  ? 'Checking the file on disk…'
                  : 'Checked the file on disk',
              onClose: summary == null
                  ? null
                  : () => Navigator.of(context).pop(),
            ),
            Flexible(
              child: summary == null
                  ? const _Busy()
                  : _Result(summary: summary),
            ),
            if (summary != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 16, 12),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Done'),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.title, required this.onClose});

  final String title;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            tooltip: 'Close',
            visualDensity: VisualDensity.compact,
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

class _Busy extends StatelessWidget {
  const _Busy();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.fromLTRB(20, 24, 20, 32),
      child: Row(
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              'Re-reading the PGN and comparing it with what is open here.',
              style: TextStyle(fontSize: 13, color: AppColors.onSurfaceSoft),
            ),
          ),
        ],
      ),
    );
  }
}

class _Result extends StatelessWidget {
  const _Result({required this.summary});

  final RepertoireReloadSummary summary;

  @override
  Widget build(BuildContext context) {
    if (summary.hasError) {
      return _Verdict(
        icon: Icons.error_outline,
        color: AppColors.danger,
        headline: 'Could not read the file',
        detail: summary.error!,
      );
    }

    if (summary.unchanged) {
      return _Verdict(
        icon: Icons.check_circle_outline,
        color: AppColors.success,
        headline: 'No changes on disk',
        detail:
            'The file still holds the same '
            '${summary.total} line${summary.total == 1 ? '' : 's'} that are '
            'open here.',
      );
    }

    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
      children: [
        _Verdict.inline(
          icon: Icons.sync,
          color: AppColors.info,
          headline: 'Reloaded from disk',
          detail:
              'This repertoire now holds '
              '${summary.total} line${summary.total == 1 ? '' : 's'}.',
        ),
        const SizedBox(height: 16),
        if (summary.added.isNotEmpty)
          _LineGroup(
            label: 'New lines found on disk',
            color: AppColors.success,
            icon: Icons.add,
            names: summary.added,
          ),
        if (summary.removed.isNotEmpty) ...[
          if (summary.added.isNotEmpty) const SizedBox(height: 14),
          _LineGroup(
            label: 'Lines no longer in the file',
            color: AppColors.danger,
            icon: Icons.remove,
            names: summary.removed,
          ),
        ],
        if (summary.edited > 0) ...[
          const SizedBox(height: 14),
          Text(
            '${summary.edited} line${summary.edited == 1 ? '' : 's'} kept the '
            'same moves but changed elsewhere — a comment, a glyph, or a '
            'sub-variation.',
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.onSurfaceMuted,
            ),
          ),
        ],
      ],
    );
  }
}

/// The one-line answer, big enough to read without leaning in.
class _Verdict extends StatelessWidget {
  const _Verdict({
    required this.icon,
    required this.color,
    required this.headline,
    required this.detail,
  }) : _inline = false;

  const _Verdict.inline({
    required this.icon,
    required this.color,
    required this.headline,
    required this.detail,
  }) : _inline = true;

  final IconData icon;
  final Color color;
  final String headline;
  final String detail;
  final bool _inline;

  @override
  Widget build(BuildContext context) {
    final body = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 22, color: color),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                headline,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                detail,
                style: const TextStyle(
                  fontSize: 13,
                  color: AppColors.onSurfaceSoft,
                ),
              ),
            ],
          ),
        ),
      ],
    );

    return Padding(
      padding: _inline
          ? EdgeInsets.zero
          : const EdgeInsets.fromLTRB(20, 8, 20, 24),
      child: body,
    );
  }
}

class _LineGroup extends StatelessWidget {
  const _LineGroup({
    required this.label,
    required this.color,
    required this.icon,
    required this.names,
  });

  final String label;
  final Color color;
  final IconData icon;
  final List<String> names;

  /// Long lists are cut here rather than scrolled forever: past a dozen names
  /// the count is the information, not the names.
  static const _maxNames = 12;

  @override
  Widget build(BuildContext context) {
    final shown = names.take(_maxNames).toList();
    final hidden = names.length - shown.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$label · ${names.length}',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
        const SizedBox(height: 6),
        for (final name in shown)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, size: 14, color: color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    name,
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppColors.inkSoft,
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (hidden > 0)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'and $hidden more',
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.onSurfaceMuted,
              ),
            ),
          ),
      ],
    );
  }
}
