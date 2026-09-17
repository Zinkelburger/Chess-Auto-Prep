import 'package:flutter/widgets.dart';
import '../repositories/stored_game_repository.dart';

/// Presentation wiring only. Load controllers receive the repository directly.
class StoredGameScope extends InheritedWidget {
  const StoredGameScope({
    super.key,
    required this.repository,
    required super.child,
  });

  final StoredGameRepository repository;

  static StoredGameRepository? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<StoredGameScope>()?.repository;

  static StoredGameRepository read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<StoredGameScope>();
    if (scope == null) throw StateError('StoredGameScope is missing');
    return scope.repository;
  }

  @override
  bool updateShouldNotify(StoredGameScope oldWidget) =>
      !identical(repository, oldWidget.repository);
}
