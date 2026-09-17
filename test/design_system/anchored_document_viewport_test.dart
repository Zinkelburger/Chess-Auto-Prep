import 'package:chess_auto_prep/design_system/layout/anchored_document_viewport.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Rows implements DocumentRows {
  _Rows(Iterable<int> keys) : keys = List.unmodifiable(keys) {
    indices = {for (var i = 0; i < this.keys.length; i++) this.keys[i]: i};
  }
  final List<int> keys;
  late final Map<int, int> indices;
  @override
  Object get revision => this;
  @override
  int get length => keys.length;
  @override
  Object keyAt(int index) => keys[index];
  @override
  int? indexOfKey(Object key) => indices[key];
}

void main() {
  testWidgets('a distant row mounts in its first frame with bounded work', (
    tester,
  ) async {
    final rows = _Rows(List.generate(50000, (i) => i));
    final selectionKey = GlobalKey();
    final built = <int>[];
    Widget host(int selected) => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 300,
          child: AnchoredDocumentViewport(
            rows: rows,
            session: 'document',
            selection: selected,
            selectedRow: rows.indexOfKey(selected),
            selectionKey: selectionKey,
            rowBuilder: (index) {
              built.add(index);
              return SizedBox(
                key: index == selected ? selectionKey : null,
                height: index.isEven ? 60 : 120,
                child: Text('Row $index'),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpWidget(host(0));
    expect(built.length, lessThan(30));
    built.clear();
    await tester.pumpWidget(host(49999));
    // Assert before settling: the viewport must not paint the previous page.
    expect(find.text('Row 49999').hitTestable(), findsOneWidget);
    expect(find.text('Row 0'), findsNothing);
    expect(built.length, lessThan(30));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 240));
    await tester.pumpAndSettle();
    expect(find.text('Row 49998'), findsOneWidget);
    await tester.pumpWidget(host(0));
    expect(find.text('Row 0').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('row insertion retains the anchored item and its widget state', (
    tester,
  ) async {
    final selectionKey = GlobalKey();
    final session = Object();
    Widget host(_Rows rows) => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 300,
          child: AnchoredDocumentViewport(
            rows: rows,
            session: session,
            selection: 50,
            selectedRow: rows.indexOfKey(50),
            selectionKey: selectionKey,
            rowBuilder: (index) => SizedBox(
              height: 60,
              key: rows.keyAt(index) == 50 ? selectionKey : null,
              child: TextField(key: ValueKey(rows.keyAt(index))),
            ),
          ),
        ),
      ),
    );
    await tester.pumpWidget(host(_Rows(List.generate(100, (i) => i))));
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey<Object>(50));
    await tester.enterText(field, 'Retained local state');
    await tester.pumpWidget(host(_Rows([-1, ...List.generate(100, (i) => i)])));
    await tester.pumpAndSettle();
    expect(field.hitTestable(), findsOneWidget);
    expect(find.text('Retained local state'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('empty documents and session replacement revoke old row state', (
    tester,
  ) async {
    final selectionKey = GlobalKey();
    Widget host(_Rows rows, String session) => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 300,
          child: AnchoredDocumentViewport(
            rows: rows,
            session: session,
            selection: 1,
            selectedRow: rows.indexOfKey(1),
            selectionKey: selectionKey,
            rowBuilder: (index) => SizedBox(
              height: 60,
              key: rows.keyAt(index) == 1 ? selectionKey : null,
              child: TextField(key: ValueKey(rows.keyAt(index))),
            ),
          ),
        ),
      ),
    );
    final rows = _Rows([0, 1, 2]);
    await tester.pumpWidget(host(rows, 'first'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey<Object>(1)), 'Old document');
    await tester.pumpWidget(host(_Rows([]), 'first'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    await tester.pumpWidget(host(rows, 'second'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<Object>(1)).hitTestable(), findsOneWidget);
    expect(find.text('Old document'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
