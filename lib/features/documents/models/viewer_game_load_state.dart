enum ViewerGameLoadFailure { noInput, notFound, archiveUnavailable, invalidPgn }

sealed class ViewerGameLoadState {
  const ViewerGameLoadState();
}

final class ViewerGameLoadIdle extends ViewerGameLoadState {
  const ViewerGameLoadIdle();
}

final class ViewerGameLoading extends ViewerGameLoadState {
  const ViewerGameLoading();
}

final class ViewerGameLoaded extends ViewerGameLoadState {
  const ViewerGameLoaded();
}

final class ViewerGameLoadFailed extends ViewerGameLoadState {
  const ViewerGameLoadFailed(this.failure);
  final ViewerGameLoadFailure failure;
}

final class ViewerGameLoadClosed extends ViewerGameLoadState {
  const ViewerGameLoadClosed();
}
