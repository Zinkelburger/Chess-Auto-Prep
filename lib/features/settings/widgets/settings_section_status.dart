import 'package:flutter/material.dart';
import '../controllers/section_settings_owner.dart';
import '../models/section_configuration.dart';
import '../models/settings_state.dart';

/// Shared save feedback beside ordinary and inline preferences.
class SettingsSectionStatus<C extends SectionConfiguration<C>>
    extends StatelessWidget {
  const SettingsSectionStatus({
    super.key,
    required this.owner,
    required this.policy,
  });
  final SectionSettingsOwner<C> owner;
  final String policy;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: owner,
    builder: (context, _) {
      final state = owner.state;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Text(switch (state.phase) {
                SettingsPhase.loading ||
                SettingsPhase.unloaded => 'Loading saved preferences…',
                SettingsPhase.saving => 'Saving preferences…',
                SettingsPhase.failed =>
                  state.draft == null
                      ? 'Saved preferences could not be loaded.'
                      : 'Preferences were not saved. Your changes are kept for retry.',
                SettingsPhase.ready => policy,
              }, style: Theme.of(context).textTheme.bodySmall),
            ),
            if (state.phase == SettingsPhase.failed)
              TextButton(
                onPressed: () => owner.retry().catchError((Object _) {}),
                child: const Text('Retry'),
              ),
          ],
        ),
      );
    },
  );
}
