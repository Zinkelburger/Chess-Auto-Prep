import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../ui/theme.dart';
import 'lichess_account.dart';
import 'setting_rows.dart';

/// One row: the label, its hint under it when there is one, and the
/// control on the right. The same height whatever the control, so a
/// column of rows reads as a table.
class SettingRowView extends StatelessWidget {
  const SettingRowView({super.key, required this.row});

  final SettingRow row;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final label = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(row.label, style: text.bodyMedium),
        if (row.hint case final hint?) ...[
          const SizedBox(height: Space.xs),
          Text(
            hint,
            style: row.warn
                ? text.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  )
                : text.labelSmall,
          ),
        ],
      ],
    );
    final control = Semantics(label: row.label, child: _control(row.control));
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: settingRowHeight),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Space.s),
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth <
                settingInlineWidth *
                    MediaQuery.textScalerOf(context).scale(1)) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  label,
                  const SizedBox(height: Space.s),
                  control,
                ],
              );
            }
            return Row(
              children: [
                Expanded(child: label),
                const SizedBox(width: Space.l),
                control,
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _control(SettingControl control) => switch (control) {
    ChoiceSetting() => _Choice(control),
    NumberSetting() => _Number(control, label: row.label),
    ToggleSetting(:final value, :final onChanged) => Transform.scale(
      scale: 0.75,
      child: Switch(value: value, onChanged: onChanged),
    ),
    SecretSetting() => _Secret(control),
    ActionSetting(:final label, :final run) => _button(label, run),
    AccountSetting(:final account) => _Account(account),
  };
}

Widget _button(String label, VoidCallback? run) => OutlinedButton(
  onPressed: run,
  style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
  child: Text(label),
);

/// The one button the account needs now: Log in, Cancel (with Copy link
/// when the browser did not open), Log out; a word while Lichess is asked.
class _Account extends StatelessWidget {
  const _Account(this.account);

  final LichessAccountState account;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    if (account.canRetrySave) {
      return _button('Retry save', () => unawaited(account.retrySave()));
    }
    return switch (account.status) {
      SignedOut() => _button('Log in', () => unawaited(account.logIn())),
      Connecting(:final page, :final browserOpened) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (page != null && !browserOpened) ...[
            _button('Copy link', () {
              unawaited(Clipboard.setData(ClipboardData(text: '$page')));
            }),
            const SizedBox(width: Space.s),
          ],
          _button('Cancel', () => unawaited(account.cancel())),
        ],
      ),
      Checking() => Text('Checking…', style: text.bodySmall),
      SigningOut() => Text('Logging out…', style: text.bodySmall),
      SignedIn() => _button('Log out', () => unawaited(account.logOut())),
    };
  }
}

class _Choice extends StatelessWidget {
  const _Choice(this.setting);

  final ChoiceSetting<Object> setting;

  @override
  Widget build(BuildContext context) => SegmentedButton<Object>(
    segments: [
      for (final (value, label) in setting.options)
        ButtonSegment(value: value, label: Text(label)),
    ],
    selected: {setting.value},
    showSelectedIcon: false,
    style: const ButtonStyle(
      visualDensity: VisualDensity.compact,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
    onSelectionChanged: (chosen) => setting.pick(chosen.first),
  );
}

/// A number typed into a box, or stepped with − and +. Enter or leaving
/// the box takes what was typed, kept inside the row's range.
class _Number extends StatefulWidget {
  const _Number(this.setting, {required this.label});

  final String label;

  final NumberSetting setting;

  @override
  State<_Number> createState() => _NumberState();
}

class _NumberState extends State<_Number> {
  late final _box = TextEditingController(text: '${widget.setting.value}');
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
  }

  @override
  void didUpdateWidget(_Number old) {
    super.didUpdateWidget(old);
    if (old.setting.value != widget.setting.value && !_focus.hasFocus) {
      _box.text = '${widget.setting.value}';
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocus);
    _focus.dispose();
    _box.dispose();
    super.dispose();
  }

  void _onFocus() {
    if (!_focus.hasFocus) _typed(_box.text);
  }

  void _typed(String text) {
    final typed = int.tryParse(text.trim());
    final next = (typed ?? widget.setting.value).clamp(
      widget.setting.min,
      widget.setting.max,
    );
    _box.text = '$next';
    if (next != widget.setting.value) widget.setting.onChanged(next);
  }

  void _step(int by) {
    final next = (widget.setting.value + by).clamp(
      widget.setting.min,
      widget.setting.max,
    );
    if (next != widget.setting.value) widget.setting.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final setting = widget.setting;
    final text = Theme.of(context).textTheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: const Icon(Icons.remove, size: IconSize.menu),
          tooltip: 'Decrease ${widget.label}',
          onPressed: setting.value > setting.min
              ? () => _step(-setting.step)
              : null,
          visualDensity: VisualDensity.compact,
        ),
        SizedBox(
          width: settingNumberWidth,
          child: TextField(
            controller: _box,
            focusNode: _focus,
            textAlign: TextAlign.center,
            style: monoText.copyWith(color: text.bodyMedium?.color),
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onSubmitted: _typed,
            decoration: const InputDecoration(
              isDense: true,
              contentPadding: EdgeInsets.symmetric(
                horizontal: Space.xs,
                vertical: Space.xs,
              ),
              border: OutlineInputBorder(),
            ),
          ),
        ),
        if (setting.unit case final unit?) ...[
          const SizedBox(width: Space.xs),
          Text(unit, style: text.bodySmall),
        ],
        IconButton(
          icon: const Icon(Icons.add, size: IconSize.menu),
          tooltip: 'Increase ${widget.label}',
          onPressed: setting.value < setting.max
              ? () => _step(setting.step)
              : null,
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }
}

/// A token: dots while it is typed, written when the field is left, and a
/// word after it saying whether it was kept.
class _Secret extends StatefulWidget {
  const _Secret(this.setting);

  final SecretSetting setting;

  @override
  State<_Secret> createState() => _SecretState();
}

class _SecretState extends State<_Secret> {
  final _box = TextEditingController();
  final _focus = FocusNode();
  String _given = '';
  String? _said;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
    unawaited(_load());
  }

  Future<void> _load() async {
    final value = await widget.setting.load() ?? '';
    if (!mounted) return;
    setState(() {
      _given = value;
      _box.text = value;
    });
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocus);
    _focus.dispose();
    _box.dispose();
    super.dispose();
  }

  void _onFocus() {
    if (!_focus.hasFocus) unawaited(_save(_box.text));
  }

  bool _saving = false;

  /// Enter and leaving the field both land here, often for the same
  /// value one after the other; one write goes out.
  Future<void> _save(String value) async {
    if (_saving || value.trim() == _given.trim()) return;
    _saving = true;
    try {
      final kept = await widget.setting.save(value);
      if (!mounted) return;
      setState(() {
        if (kept) _given = value;
        _said = kept
            ? (value.trim().isEmpty ? 'Signed out' : 'Saved')
            : 'Not saved';
      });
    } finally {
      _saving = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: settingSecretWidth,
          child: TextField(
            controller: _box,
            focusNode: _focus,
            obscureText: true,
            style: text.bodyMedium,
            onSubmitted: (value) => unawaited(_save(value)),
            decoration: const InputDecoration(
              isDense: true,
              contentPadding: EdgeInsets.symmetric(
                horizontal: Space.s,
                vertical: Space.xs,
              ),
              border: OutlineInputBorder(),
            ),
          ),
        ),
        if (_said case final said?) ...[
          const SizedBox(width: Space.s),
          Text(said, style: text.bodySmall),
        ],
      ],
    );
  }
}
