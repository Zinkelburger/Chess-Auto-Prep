/// A worker request owned by one document session. Cancellation releases work.
abstract interface class ViewerComputation<T> {
  Future<T> get result;
  void cancel();
}
