/// The modes `v2` has. Each one fills the left column; the workspace, the
/// document and the draft in it are the same whichever is showing.
enum Mode {
  repertoires('Repertoire builder'),
  pgnViewer('PGN Viewer'),
  study('Study'),
  tactics('Tactics'),
  myGames('My games');

  const Mode(this.label);

  final String label;
}
