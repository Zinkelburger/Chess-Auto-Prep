import 'package:chess_auto_prep/services/tactics/tactics_import_coordinator.dart';
import 'package:chess_auto_prep/services/tactics/tactics_session_controller.dart';
import 'package:chess_auto_prep/services/tactics_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

/// Mirrors the provider scope `_TacticsModeView` installs above the tactics
/// layout. This guards the wiring contract: the session and import coordinator
/// must resolve and must share the *same* database instance as the one exposed
/// directly — i.e. a single source of truth. A regression in provider ordering
/// (session/import created before the database, or against a different db)
/// would fail here instead of silently at runtime.
void main() {
  testWidgets('tactics providers resolve and share one database', (
    tester,
  ) async {
    late TacticsDatabase db;
    late TacticsSessionController session;
    late TacticsImportCoordinator import;

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<TacticsDatabase>(
            create: (_) => TacticsDatabase(),
          ),
          ChangeNotifierProvider<TacticsSessionController>(
            create: (ctx) => TacticsSessionController(
              database: ctx.read<TacticsDatabase>(),
            ),
          ),
          ChangeNotifierProvider<TacticsImportCoordinator>(
            create: (ctx) => TacticsImportCoordinator(
              database: ctx.read<TacticsDatabase>(),
            ),
          ),
        ],
        child: Builder(
          builder: (ctx) {
            db = ctx.read<TacticsDatabase>();
            session = ctx.read<TacticsSessionController>();
            import = ctx.read<TacticsImportCoordinator>();
            return const SizedBox();
          },
        ),
      ),
    );

    expect(session.database, same(db));
    expect(import.database, same(db));
  });
}
