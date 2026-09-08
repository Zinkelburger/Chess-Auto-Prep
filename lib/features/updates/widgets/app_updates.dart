import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../theme/app_text_styles.dart';
import '../../../widgets/settings/settings_widgets.dart';
import '../services/app_update_service.dart';
import '../services/update_release.dart';

/// Lives below the Navigator, so startup notifications can open a dialog.
class AppUpdateHost extends StatefulWidget {
  const AppUpdateHost({super.key, required this.child, this.service});
  final Widget child;
  final AppUpdateService? service;
  @override
  State<AppUpdateHost> createState() => _AppUpdateHostState();
}

class _AppUpdateHostState extends State<AppUpdateHost> {
  late final service = widget.service ?? AppUpdateService.instance;
  String? _shown;
  bool _showedError = false;
  @override
  void initState() {
    super.initState();
    service.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(service.start());
    });
  }

  void _changed() {
    if (mounted && !_showedError && service.previousInstallError != null) {
      _showedError = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(
          showDialog<void>(
            context: context,
            builder: (dialogContext) => AlertDialog(
              title: const Text('The previous update did not finish'),
              content: SelectableText(service.previousInstallError!),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('OK'),
                ),
              ],
            ),
          ),
        );
      });
    }
    if (!mounted ||
        service.release == null ||
        service.release!.tag == _shown ||
        service.phase != UpdatePhase.available) {
      return;
    }
    final announcedRelease = service.release!;
    _shown = announcedRelease.tag;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        showDialog<void>(
          context: context,
          builder: (_) => AlertDialog(
            title: Text(
              'Chess Auto Prep ${announcedRelease.version} is available',
            ),
            content: SizedBox(
              width: 520,
              child: SingleChildScrollView(
                child: UpdateControls(service: service),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Later'),
              ),
            ],
          ),
        ),
      );
    });
  }

  @override
  void dispose() {
    service.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class UpdateSettingsSection extends StatelessWidget {
  const UpdateSettingsSection({super.key, this.service});
  final AppUpdateService? service;
  @override
  Widget build(BuildContext context) {
    final updates = service ?? AppUpdateService.instance;
    return SettingsGroup(
      title: 'App updates',
      icon: Icons.system_update_alt,
      subtitle:
          'Stable releases from GitHub. Install after you finish your work.',
      children: [
        Padding(
          padding: const EdgeInsets.all(20),
          child: UpdateControls(service: updates, settings: true),
        ),
      ],
    );
  }
}

class UpdateControls extends StatelessWidget {
  const UpdateControls({
    super.key,
    required this.service,
    this.settings = false,
  });
  final AppUpdateService service;
  final bool settings;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: service,
    builder: (context, _) {
      final release = service.release;
      final status = switch (service.phase) {
        UpdatePhase.idle =>
          service.hasChecked
              ? 'No newer release found.'
              : 'Updates are checked against stable GitHub releases.',
        UpdatePhase.checking => 'Checking GitHub releases…',
        UpdatePhase.available =>
          service.canInstall
              ? 'An update is available to download.'
              : 'An update is available. Install it using your package manager or the release download.',
        UpdatePhase.downloading =>
          'Downloading update… ${(service.progress * 100).round()}%',
        UpdatePhase.ready =>
          'Update downloaded and verified. Choose when to install it.',
        UpdatePhase.scheduled =>
          'The app will update and reopen after you close it normally. Finish and save your work first. Linux packages may ask for your administrator password.',
        UpdatePhase.failed => 'Update could not complete: ${service.error}',
      };
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (service.previousInstallError != null)
            Text(service.previousInstallError!, style: AppTextStyles.muted),
          if (settings) ...[
            Text(
              service.currentVersion.isEmpty
                  ? 'Chess Auto Prep'
                  : 'Installed version: ${service.currentVersion}',
              style: AppTextStyles.bodyStrong,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Check for updates automatically'),
              subtitle: const Text(
                'At startup and at most once a day while the app is open.',
              ),
              value: service.automaticChecks,
              onChanged: (v) => unawaited(service.setAutomaticChecks(v)),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Download updates automatically'),
              subtitle: const Text(
                'Show an update popup. Installation waits until you choose it and close the app. Changes apply to future downloads.',
              ),
              value: service.automaticDownload,
              onChanged: (v) => unawaited(service.setAutomaticDownload(v)),
            ),
            if (!service.canInstall)
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Text(
                  'This installation uses manual updates (including Flatpak, Windows portable, unmarked Linux bundles, and development builds).',
                  style: AppTextStyles.muted,
                ),
              ),
          ],
          Text(status, style: AppTextStyles.body),
          if (service.phase == UpdatePhase.downloading) ...[
            const SizedBox(height: 12),
            LinearProgressIndicator(value: service.progress),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (settings)
                OutlinedButton(
                  onPressed:
                      service.busy || service.phase == UpdatePhase.scheduled
                      ? null
                      : () => unawaited(service.check()),
                  child: const Text('Check now'),
                ),
              if (release != null)
                TextButton(
                  onPressed: () => unawaited(_open(context, release.page)),
                  child: const Text('Release notes'),
                ),
              if (service.canInstall &&
                  (service.phase == UpdatePhase.available ||
                      service.phase == UpdatePhase.failed && release != null))
                FilledButton(
                  onPressed: () => unawaited(service.download()),
                  child: const Text('Download update'),
                ),
              if (service.phase == UpdatePhase.ready)
                FilledButton(
                  onPressed: () => unawaited(service.scheduleInstall()),
                  child: const Text('Install when I close the app'),
                ),
              if (service.phase == UpdatePhase.scheduled)
                OutlinedButton(
                  onPressed: service.canCancelInstall
                      ? () => unawaited(service.cancelInstall())
                      : null,
                  child: const Text('Cancel installation'),
                ),
              if (!service.canInstall)
                OutlinedButton(
                  onPressed: () =>
                      unawaited(_open(context, release?.page ?? releasesPage)),
                  child: const Text('Open releases'),
                ),
            ],
          ),
          if (service.downloadDirectory != null &&
              service.phase == UpdatePhase.failed)
            SelectableText(
              'Installer logs: ${service.downloadDirectory}',
              style: AppTextStyles.muted,
            ),
        ],
      );
    },
  );

  Future<void> _open(BuildContext context, Uri uri) async {
    try {
      if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return;
    } catch (_) {
      /* Present the actionable URL below. */
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Could not open $uri')));
  }
}
