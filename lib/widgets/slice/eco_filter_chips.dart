import 'package:flutter/material.dart';

import '../../models/pgn_filter_models.dart';
import '../../services/opening_catalog.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import '../common/static_board_thumbnail.dart';
import '../position_preview_icon.dart';

/// Recognize only exact codes and the picker’s union expression. Arbitrary
/// prefixes, exclusions and regexes retain the ordinary editable value field.
List<String> selectedEcoCodes(String value, MatchMode mode) {
  final code = RegExp(r'^[A-E]\d{2}$');
  if (mode == MatchMode.exact && code.hasMatch(value)) return [value];
  if (mode != MatchMode.regex ||
      !value.startsWith('^(') ||
      !value.endsWith(r')$')) {
    return [];
  }
  final codes = value.substring(2, value.length - 2).split('|');
  return codes.every(code.hasMatch) ? codes.toSet().toList() : [];
}

String ecoCodeExpression(List<String> codes) => codes.length <= 1
    ? codes.firstOrNull ?? ''
    : '^(${codes.map(RegExp.escape).join('|')})\$';

/// Selected ECO codes reuse the app’s chips and inexpensive board thumbnails.
/// A thumbnail represents one named opening within the selected code.
class EcoFilterChips extends StatefulWidget {
  const EcoFilterChips({
    super.key,
    required this.codes,
    required this.onChanged,
    this.openings,
  });

  final List<String> codes;
  final ValueChanged<List<String>> onChanged;
  final Future<List<CatalogOpening>>? openings;

  @override
  State<EcoFilterChips> createState() => _EcoFilterChipsState();
}

class _EcoFilterChipsState extends State<EcoFilterChips> {
  late final _loading = widget.openings ?? OpeningCatalog.load();
  bool _showThumbnails = true;

  @override
  Widget build(BuildContext context) => FutureBuilder<List<CatalogOpening>>(
    future: _loading,
    builder: (context, snapshot) {
      final byCode = <String, CatalogOpening>{};
      for (final opening in snapshot.data ?? <CatalogOpening>[]) {
        byCode.putIfAbsent(opening.eco, () => opening);
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final code in widget.codes)
                PositionHoverPreview(
                  inputGetter: () => byCode[code]?.position.fen ?? '',
                  child: InputChip(
                    backgroundColor: Theme.of(context).colorScheme.surface,
                    side: const BorderSide(color: AppColors.divider),
                    label: SizedBox(
                      height: _showThumbnails && byCode[code] != null
                          ? 48
                          : null,
                      child: Center(
                        widthFactor: 1,
                        child: Text(code, style: AppTextStyles.body),
                      ),
                    ),
                    tooltip: byCode[code] == null
                        ? code
                        : '$code · ${byCode[code]!.name} (example position)',
                    avatarBoxConstraints:
                        _showThumbnails && byCode[code] != null
                        ? const BoxConstraints.tightFor(width: 48, height: 48)
                        : null,
                    avatar: _showThumbnails && byCode[code] != null
                        ? StaticBoardThumbnail(
                            fen: byCode[code]!.position.fen,
                            size: 48,
                            flipped: false,
                          )
                        : null,
                    deleteIconColor: AppColors.onSurfaceMuted,
                    onDeleted: () {
                      if (!mounted) return;
                      widget.onChanged(
                        widget.codes.where((c) => c != code).toList(),
                      );
                    },
                  ),
                ),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Checkbox(
                value: _showThumbnails,
                visualDensity: VisualDensity.compact,
                onChanged: (value) {
                  if (!mounted) return;
                  setState(() => _showThumbnails = value ?? true);
                },
              ),
              Flexible(
                child: Text(
                  'Show thumbnails',
                  style: AppTextStyles.forTheme(context, AppTextStyles.caption),
                ),
              ),
            ],
          ),
        ],
      );
    },
  );
}
