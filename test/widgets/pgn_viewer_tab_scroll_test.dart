/// Regression test: navigating the game while the side panel shows another
/// tab must not drag the TabBarView back to the Game tab.
///
/// PgnViewerWidget keeps itself alive behind the TabBarView and auto-scrolls
/// the current move into view on navigation. Using the static
/// `Scrollable.ensureVisible` there also scrolled the enclosing TabBarView's
/// PageView, so pressing ← on the Analysis tab yanked the panel back to the
/// Game tab.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/widgets/pgn_viewer_widget.dart';

void main() {
  testWidgets('mainline navigation with Game tab offstage keeps current tab', (
    tester,
  ) async {
    final controller = PgnViewerWidgetController();
    late TabController tabs;

    await tester.pumpWidget(
      MaterialApp(
        home: DefaultTabController(
          length: 2,
          child: Builder(
            builder: (context) {
              tabs = DefaultTabController.of(context);
              return Scaffold(
                appBar: AppBar(
                  bottom: const TabBar(
                    tabs: [
                      Tab(text: 'Game'),
                      Tab(text: 'Analysis'),
                    ],
                  ),
                ),
                body: TabBarView(
                  children: [
                    PgnViewerWidget(
                      pgnText: '1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 4. Ba4 Nf6',
                      controller: controller,
                    ),
                    const Center(child: Text('analysis body')),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(controller.mainLineLength, 8, reason: 'game should have loaded');

    await tester.tap(find.text('Analysis'));
    await tester.pumpAndSettle();
    expect(tabs.index, 1);

    // Navigate the (offstage, kept-alive) game; the movetext auto-scroll must
    // not touch the TabBarView.
    controller.goForward();
    await tester.pumpAndSettle();
    controller.goForward();
    await tester.pumpAndSettle();

    expect(tabs.index, 1, reason: 'navigation must not switch tabs');
    expect(
      controller.mainLineIndex,
      2,
      reason: 'navigation should still work while offstage',
    );
  });
}
