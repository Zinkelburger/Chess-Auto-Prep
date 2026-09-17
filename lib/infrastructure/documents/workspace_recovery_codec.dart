/// Each workspace owns its payload schema; the checkpoint envelope, leases and
/// exact-revision resolution protocol are shared. Keep different payload types
/// in separate directories so an older reader never consumes another workspace.
abstract interface class WorkspaceRecoveryCodec<T> {
  Map<String, Object?> encode(T snapshot);
  T decode(Map<String, dynamic> data);
  bool needsRecovery(T snapshot);
}
