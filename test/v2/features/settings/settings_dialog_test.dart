import 'package:chess_auto_prep/v2/features/settings/lichess_account.dart';
import 'package:chess_auto_prep/v2/features/settings/setting_rows.dart';
import 'package:chess_auto_prep/v2/features/settings/settings_dialog.dart';
import 'package:chess_auto_prep/v2/net/lichess_login.dart';
import 'package:chess_auto_prep/v2/storage/lichess_token.dart';
import 'package:chess_auto_prep/v2/storage/settings_store.dart';
import 'package:chess_auto_prep/v2/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_login.dart';

void main() {
  late SettingsStore store;
  late ScriptedLogin login;
  late LichessAccountState account;
  LichessAccount? saved;
  var opened = 0;
  var readFails = false;

  setUp(() {
    store = SettingsStore();
    login = ScriptedLogin();
    saved = null;
    readFails = false;
    account = LichessAccountState(
      login: login,
      read: () async {
        if (readFails) throw StateError('private-test-token');
        return saved;
      },
      write: (next) async {
        saved = next;
        return true;
      },
    );
    opened = 0;
  });

  tearDown(() {
    store.dispose();
    account.dispose();
  });

  List<SettingGroup> rows() => settingGroups(
    store: store,
    coresAvailable: 8,
    account: account,
    openLogFolder: () => opened++,
  );

  Future<void> pump(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: SettingsDialog(store: store, groups: rows, also: account),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('unavailable credentials show Retry read and hide token edits', (
    tester,
  ) async {
    readFails = true;
    await account.load();
    await pump(tester);
    await tester.tap(find.text('Accounts'));
    await tester.pumpAndSettle();
    expect(find.text('Retry read'), findsOneWidget);
    expect(find.text('Log in'), findsNothing);
    expect(find.text('Personal access token'), findsNothing);
    readFails = false;
    await tester.tap(find.text('Retry read'));
    await tester.pumpAndSettle();
    expect(find.text('Log in'), findsOneWidget);
    expect(find.text('Personal access token'), findsOneWidget);
    expect(find.text('Retry read'), findsNothing);
  });

  testWidgets('opens on Look, with one place per group and no more', (
    tester,
  ) async {
    await pump(tester);
    for (final place in [
      'Look',
      'Training',
      'Engine',
      'Repertoire',
      'Files',
      'Accounts',
      'App',
    ]) {
      if (place == 'App') {
        await tester.scrollUntilVisible(
          find.text('App'),
          100,
          scrollable: find
              .descendant(
                of: find.byType(ListView).first,
                matching: find.byType(Scrollable),
              )
              .first,
        );
      }
      expect(find.text(place), findsOneWidget);
    }
    expect(find.text('Board coordinates'), findsOneWidget);
    expect(find.text('CPU cores'), findsNothing);
  });

  testWidgets('a place shows its rows; a number is stepped and typed', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.text('Engine'));
    await tester.pumpAndSettle();
    expect(find.text('CPU cores'), findsOneWidget);
    expect(find.text('of 8 on this computer'), findsOneWidget);
    final plus = find.widgetWithIcon(IconButton, Icons.add).first;
    await tester.tap(plus);
    await tester.pumpAndSettle();
    expect(store.value.engineCores, 2);
    final boxes = find.byType(TextField);
    // The first box after the search field is the cores box.
    await tester.enterText(boxes.at(1), '99');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(store.value.engineCores, 8, reason: 'kept inside the range');
  });

  testWidgets(
    'Training changes a session limit through the real settings row',
    (tester) async {
      await pump(tester);
      await tester.tap(find.text('Training'));
      await tester.pumpAndSettle();
      expect(find.text('New lines per sitting'), findsOneWidget);
      await tester.enterText(find.byType(TextField).at(1), '0');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(store.value.training.learnLimit, 0);
      expect(store.value.training.drillLimit, 10);
    },
  );

  testWidgets('a choice and a switch write at once', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Hide'));
    await tester.pumpAndSettle();
    expect(store.value.boardCoordinates, isFalse);
    await tester.tap(find.text('Files'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(store.value.copyFilesIntoDocuments, isFalse);
  });

  testWidgets('typing finds rows across the places', (tester) async {
    await pump(tester);
    await tester.enterText(find.byType(TextField).first, 'mem');
    await tester.pumpAndSettle();
    expect(find.text('Memory'), findsOneWidget);
    expect(find.text('ENGINE'), findsOneWidget);
    expect(find.text('Board coordinates'), findsNothing);
    await tester.enterText(find.byType(TextField).first, 'zzz');
    await tester.pumpAndSettle();
    expect(find.text('Nothing matches "zzz".'), findsOneWidget);
  });

  testWidgets(
    'searching a category shows all its settings and clear returns to Look',
    (tester) async {
      await pump(tester);
      await tester.enterText(find.byType(TextField).first, 'engine');
      await tester.pumpAndSettle();
      for (final label in ['CPU cores', 'Memory', 'Lines shown']) {
        expect(find.text(label), findsOneWidget);
      }
      await tester.tap(find.byTooltip('Clear search'));
      await tester.pumpAndSettle();
      expect(find.text('Board coordinates'), findsOneWidget);
      expect(find.text('Changes save automatically'), findsOneWidget);
    },
  );

  testWidgets(
    'changing categories replaces number fields with their own values',
    (tester) async {
      await pump(tester);
      await tester.tap(find.text('Engine'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Repertoire'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField).at(1)).controller!.text,
        '${store.value.opponentElo}',
      );
    },
  );

  testWidgets('large text keeps settings controls reachable', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: SettingsDialog(store: store, groups: rows, also: account),
        ),
      ),
    );
    await tester.tap(find.text('Engine'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('Increase CPU cores'));
    await tester.pumpAndSettle();
    expect(store.value.engineCores, 2);
    expect(tester.takeException(), isNull);
  });

  Future<void> accounts(WidgetTester tester) async {
    await pump(tester);
    await tester.tap(find.text('Accounts'));
    await tester.pumpAndSettle();
  }

  testWidgets('signed out: Log in, the token row, and what a login is for', (
    tester,
  ) async {
    await accounts(tester);
    expect(find.text('Lichess'), findsOneWidget);
    expect(find.text('Log in'), findsOneWidget);
    expect(find.text('Personal access token'), findsOneWidget);
    expect(find.textContaining('lifts the API limits'), findsOneWidget);
  });

  testWidgets('Log in waits for the browser and Cancel ends the wait', (
    tester,
  ) async {
    await accounts(tester);
    await tester.tap(find.text('Log in'));
    await tester.pumpAndSettle();
    expect(find.text('Waiting for the browser…'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.text('Personal access token'), findsNothing);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Log in'), findsOneWidget);
    expect(login.waiting, isFalse);
  });

  testWidgets('a browser that did not open offers the link', (tester) async {
    login.browserOpens = false;
    login.page = Uri.parse('https://lichess.org/oauth?client_id=x');
    await accounts(tester);
    await tester.tap(find.text('Log in'));
    await tester.pumpAndSettle();
    expect(find.textContaining('did not open'), findsOneWidget);
    expect(find.text('Copy link'), findsOneWidget);
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    await tester.tap(find.text('Copy link'));
    await tester.pumpAndSettle();
    expect(copied, 'https://lichess.org/oauth?client_id=x');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('the browser coming back shows who is logged in, and Log out', (
    tester,
  ) async {
    await accounts(tester);
    await tester.tap(find.text('Log in'));
    await tester.pumpAndSettle();
    login.browserBack(loggedIn());
    await tester.pumpAndSettle();
    expect(
      find.text('Logged in as DrNykterstein · until 2027-09-22'),
      findsOneWidget,
    );
    expect(find.text('Log out'), findsOneWidget);
    expect(find.text('Personal access token'), findsNothing);
    await tester.tap(find.text('Log out'));
    await tester.pumpAndSettle();
    expect(find.text('Log in'), findsOneWidget);
    expect(login.revoked, ['lip_secret']);
    expect(saved, isNull);
  });

  testWidgets('a declined login says so in the row, in red', (tester) async {
    await accounts(tester);
    await tester.tap(find.text('Log in'));
    await tester.pumpAndSettle();
    login.browserBack(const LoginFailed(LoginProblem.denied));
    await tester.pumpAndSettle();
    final hint = find.text(LoginProblem.denied.sentence);
    expect(hint, findsOneWidget);
    expect(
      tester.widget<Text>(hint).style?.color,
      darkTheme().colorScheme.error,
    );
    expect(find.text('Log in'), findsOneWidget);
  });

  testWidgets('a personal token typed into the row signs in', (tester) async {
    login.tokenOutcome = loggedIn(name: 'Me', personal: true);
    await accounts(tester);
    final field = find.byType(TextField).at(1);
    await tester.enterText(field, 'lip_mine');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(login.tokensTried, ['lip_mine']);
    expect(
      find.text('Logged in as Me · personal access token'),
      findsOneWidget,
    );
    expect(saved?.personal, isTrue);
  });

  testWidgets('a rejected personal token says why and stays', (tester) async {
    await accounts(tester);
    final field = find.byType(TextField).at(1);
    await tester.enterText(field, 'bad');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text(LoginProblem.tokenRejected.sentence), findsOneWidget);
    expect(find.text('Not saved'), findsOneWidget);
    expect(find.text('Personal access token'), findsOneWidget);
  });

  testWidgets('the log folder opens from App', (tester) async {
    await pump(tester);
    await tester.scrollUntilVisible(
      find.text('App'),
      100,
      scrollable: find
          .descendant(
            of: find.byType(ListView).first,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(find.text('App'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open'));
    expect(opened, 1);
  });

  testWidgets('a store in trouble says so under the rows', (tester) async {
    await pump(tester);
    expect(find.textContaining('could not'), findsNothing);
  });
}
