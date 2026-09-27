import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../controllers/study_controller.dart';

/// Read-only subscription to the injected session. Provider owns only this
/// subscription, never the session or another mutable copy of its action state.
class StudySelector<T> extends StatelessWidget {
  const StudySelector({
    super.key,
    required this.study,
    required this.select,
    required this.builder,
  });

  final StudyController study;
  final T Function(StudyController) select;
  final Widget Function(BuildContext, T) builder;

  @override
  Widget build(BuildContext context) =>
      ListenableProvider<StudyController>.value(
        value: study,
        child: Selector<StudyController, T>(
          selector: (_, owner) => select(owner),
          shouldRebuild: (before, after) => before != after,
          builder: (context, value, _) => builder(context, value),
        ),
      );
}
