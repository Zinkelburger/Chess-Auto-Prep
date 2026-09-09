import 'package:flutter/material.dart';

import '../../../services/games_library/game_filter.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../../../widgets/labeled_toggle.dart';
import '../controllers/recent_games_controller.dart';
import '../services/games_window.dart';
import 'games_window_picker.dart';

/// What the user chose, handed back to the pane so one Apply produces one
/// reload.
class HomeReviewSettingsResult {
  const HomeReviewSettingsResult({required this.filters, required this.window});

  final GamesListFilters filters;

  /// The shared games window as the dialog left it (see [GamesWindow]).
  final GamesWindow window;
}

/// Game downloads, edited as a draft until Apply.
class HomeReviewSettingsDialog extends StatefulWidget {
  const HomeReviewSettingsDialog({
    super.key,
    required this.filters,
    required this.window,
    this.embedded = false,
    this.onApply,
  });

  final GamesListFilters filters;

  final bool embedded;

  /// Embedded hosts apply changes without closing the shared settings route.
  final Future<void> Function(HomeReviewSettingsResult)? onApply;

  /// The shared window as it stands; edited as a draft here so Cancel leaves
  /// it alone.
  final GamesWindow window;

  @override
  State<HomeReviewSettingsDialog> createState() =>
      _HomeReviewSettingsDialogState();
}

class _HomeReviewSettingsDialogState extends State<HomeReviewSettingsDialog> {
  late Set<GameSpeed> _speeds;
  late bool _autoRun;
  late GamesWindow _window;
  late final TextEditingController _bookCheck;

  @override
  void initState() {
    super.initState();
    _speeds = {...widget.filters.speeds};
    _autoRun = widget.filters.autoRun;
    _window = widget.window;
    _bookCheck = TextEditingController(text: '${_window.bookCheckGames}');
  }

  @override
  void dispose() {
    _bookCheck.dispose();
    super.dispose();
  }

  bool _saving = false;
  String? _saveMessage;

  /// Out-of-range and unparseable input is clamped rather than rejected: a
  /// dialog that refuses to close over a typo in a box you can see is worse
  /// than one that quietly puts the number back in range.
  Future<void> _apply() async {
    if (!mounted || _saving) return;
    // Commit any pending typed stepper value before saving the draft.
    FocusManager.instance.primaryFocus?.unfocus();
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;
    final bookCheck = int.tryParse(_bookCheck.text.trim());
    final window = bookCheck == null
        ? _window
        : _window.copyWith(bookCheckGames: bookCheck);
    final result = HomeReviewSettingsResult(
      filters: widget.filters.copyWith(speeds: _speeds, autoRun: _autoRun),
      window: window,
    );
    if (widget.onApply == null) {
      Navigator.of(context).pop(result);
      return;
    }
    setState(() {
      _saving = true;
      _saveMessage = null;
    });
    try {
      await widget.onApply!(result);
      if (mounted) setState(() => _saveMessage = 'Review settings saved.');
    } catch (_) {
      if (mounted) {
        setState(
          () => _saveMessage =
              'Could not save review settings. Please try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final content = SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _label('Games to analyse'),
          GamesWindowPicker(
            window: _window,
            onChanged: (w) {
              if (!mounted) return;
              setState(() => _window = w);
            },
          ),
          _label('Time controls'),
          for (final speed in selectableGameSpeeds)
            AppCheckbox(
              label: speed.label,
              value: _speeds.contains(speed),
              onChanged: (checked) {
                if (!mounted) return;
                setState(() {
                  if (checked == true) {
                    _speeds.add(speed);
                  } else {
                    _speeds.remove(speed);
                  }
                });
              },
            ),
          _label('Book check'),
          _numberField(
            key: const Key('book-check-games-field'),
            controller: _bookCheck,
            label: 'Games per site',
          ),
          _label('When it runs'),
          AppCheckbox(
            key: const Key('review-auto-start'),
            label: 'Check for new games when the app starts',
            value: _autoRun,
            onChanged: (v) {
              if (!mounted) return;
              setState(() => _autoRun = v);
            },
          ),
        ],
      ),
    );
    if (widget.embedded) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: content),
            const SizedBox(height: 12),
            if (_saveMessage != null)
              Text(_saveMessage!, style: AppTextStyles.muted),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: _saving ? null : _apply,
                child: Text(_saving ? 'Saving…' : 'Apply'),
              ),
            ),
          ],
        ),
      );
    }
    return AlertDialog(
      title: const Text('Game downloads', style: AppTextStyles.bodyStrong),
      content: SizedBox(width: 400, child: content),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _apply, child: const Text('Apply')),
      ],
    );
  }

  /// A number box with its label on its own line: the box holds two digits, and
  /// a floating `labelText` would be clipped to that width.
  Widget _numberField({
    required Key key,
    required TextEditingController controller,
    required String label,
    String? hint,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: AppTextStyles.body.copyWith(
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        SizedBox(
          width: 96,
          child: TextField(
            key: key,
            controller: controller,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 10,
              ),
            ),
          ),
        ),
        if (hint != null) ...[
          const SizedBox(height: 6),
          Text(
            hint,
            style: AppTextStyles.body.copyWith(
              fontSize: 12,
              color: AppColors.onSurfaceMuted,
            ),
          ),
        ],
      ],
    );
  }

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(top: 16, bottom: 4),
    child: Text(
      text,
      style: AppTextStyles.body.copyWith(
        fontSize: 12,
        fontWeight: FontWeight.w700,
        color: AppColors.onSurfaceMuted,
      ),
    ),
  );
}
