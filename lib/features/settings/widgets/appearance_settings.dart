import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../design_system/theme/app_spacing.dart';
import '../../../design_system/theme/app_typography.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../controllers/settings_providers.dart';
import '../models/app_appearance.dart';
import '../models/settings_state.dart';

class AppearanceSettings extends ConsumerWidget {
  const AppearanceSettings({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repository = ref.watch(appSettingsRepositoryProvider).appearance;
    final state =
        ref.watch(appearanceSettingsProvider).asData?.value ?? repository.state;
    final copy = AppLocalizations.of(context);
    final selected = state.draft ?? state.committed ?? AppAppearance.dark;
    void run(Future<void> action) =>
        unawaited(action.catchError((Object _) {}));
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        Text(copy.appearance, style: AppTypography.title(context)),
        const SizedBox(height: AppSpacing.md),
        LayoutBuilder(
          builder: (context, constraints) => Align(
            alignment: Alignment.centerLeft,
            child: SegmentedButton<AppAppearance>(
              direction:
                  constraints.maxWidth <
                      360 * MediaQuery.textScalerOf(context).scale(1)
                  ? Axis.vertical
                  : Axis.horizontal,
              segments: [
                ButtonSegment(
                  value: AppAppearance.dark,
                  label: Text(copy.appearanceDark),
                ),
                ButtonSegment(
                  value: AppAppearance.light,
                  label: Text(copy.appearanceLight),
                ),
                ButtonSegment(
                  value: AppAppearance.system,
                  label: Text(copy.appearanceSystem),
                ),
              ],
              selected: {selected},
              onSelectionChanged: state.busy
                  ? null
                  : (values) => run(repository.setAppearance(values.single)),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        if (state.busy)
          Row(
            children: [
              const SizedBox.square(
                dimension: AppSpacing.lg,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Text(
                  state.phase == SettingsPhase.loading
                      ? copy.appearanceLoading
                      : copy.appearanceSaving,
                ),
              ),
            ],
          )
        else if (state.phase == SettingsPhase.failed)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                copy.appearanceFailed,
                style: AppTypography.body(
                  context,
                ).copyWith(color: Theme.of(context).colorScheme.error),
              ),
              Wrap(
                spacing: AppSpacing.md,
                children: [
                  TextButton(
                    onPressed: () => run(repository.retry()),
                    child: Text(copy.retry),
                  ),
                  TextButton(
                    onPressed: () => run(repository.reload()),
                    child: Text(copy.appearanceReload),
                  ),
                ],
              ),
            ],
          )
        else
          Text(
            copy.appearanceSystemHelp,
            style: AppTypography.secondary(context),
          ),
      ],
    );
  }
}
