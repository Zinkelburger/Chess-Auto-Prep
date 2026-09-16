import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/repertoires/controllers/repertoire_catalog_controller.dart';
import '../features/repertoires/repositories/repertoire_catalog_repository.dart';
import '../infrastructure/repertoires/legacy_repertoire_catalog_repository.dart';
import '../services/storage/storage_factory.dart';

/// Composition root for migrated features. Legacy Provider owners remain under
/// this scope until their own feature migrates; they never own catalog state.
class AppDependencies extends StatefulWidget {
  const AppDependencies({
    super.key,
    required this.child,
    this.repertoireCatalog,
  });

  final Widget child;
  final RepertoireCatalogRepository? repertoireCatalog;

  @override
  State<AppDependencies> createState() => _AppDependenciesState();
}

class _AppDependenciesState extends State<AppDependencies> {
  late final _defaultCatalog = LegacyRepertoireCatalogRepository(
    StorageFactory.instance,
  );

  @override
  Widget build(BuildContext context) => ProviderScope(
    retry: (count, error) => null,
    overrides: [
      repertoireCatalogRepositoryProvider.overrideWithValue(
        widget.repertoireCatalog ?? _defaultCatalog,
      ),
    ],
    child: widget.child,
  );
}
