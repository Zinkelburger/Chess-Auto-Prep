import '../../features/documents/repositories/viewer_computation.dart';
import '../../utils/isolate_task.dart';

class IsolateViewerComputation<T> implements ViewerComputation<T> {
  IsolateViewerComputation(Future<T> Function(IsolateTask) run) {
    result = run(_task);
  }
  final _task = IsolateTask();
  @override
  late final Future<T> result;
  @override
  void cancel() => _task.cancel();
}
