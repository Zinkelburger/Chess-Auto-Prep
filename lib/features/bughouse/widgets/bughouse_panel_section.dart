/// The collapsed block the lab's side panel is built out of, and the caption
/// that labels a control inside one.
///
/// Shared by the analysis panel and the tournament panel because the panel is
/// 400 pixels wide and both have the same problem: real inputs that are not
/// what you look at while something is running. A closed section with a
/// one-line summary answers "what is it set to" without spending the height
/// of the controls that set it.
library;

import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';

class BughousePanelSection extends StatefulWidget {
  const BughousePanelSection({
    super.key,
    required this.title,
    required this.summary,
    required this.children,
    this.initiallyOpen = false,
  });

  final String title;

  /// What the section says while it is shut — the current setting, not a
  /// description of the control.
  final String summary;

  final List<Widget> children;
  final bool initiallyOpen;

  @override
  State<BughousePanelSection> createState() => _BughousePanelSectionState();
}

class _BughousePanelSectionState extends State<BughousePanelSection> {
  late bool _open = widget.initiallyOpen;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.divider),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(widget.title, style: AppTextStyles.eyebrow),
                        const SizedBox(height: 2),
                        Text(
                          widget.summary,
                          style: AppTextStyles.caption,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    _open ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: AppColors.onSurfaceMuted,
                  ),
                ],
              ),
            ),
          ),
          if (_open)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: widget.children,
              ),
            ),
        ],
      ),
    );
  }
}

/// The caption above one control inside a section.
class BughousePanelLabel extends StatelessWidget {
  const BughousePanelLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(text, style: AppTextStyles.caption),
  );
}
