/// Synthetic legal course shared by stage and native diagnostics.
String largeStudyPgn() {
  final pgn = StringBuffer(
    '[Event "Large course"]\n\n1. Nf3 {Branch 0 move 0.} ',
  );
  for (var branch = 1; branch < 100; branch++) {
    pgn.write('(${_line(branch)}) ');
  }
  pgn.write('${_line(0, start: 1)} *');
  return pgn.toString();
}

String _line(int branch, {int start = 0}) {
  final text = StringBuffer();
  const moves = ['Nf3', 'Nf6', 'Ng1', 'Ng8'];
  for (var ply = start; ply < 200; ply++) {
    if (ply.isEven || ply == start) {
      text.write('${ply ~/ 2 + 1}${ply.isEven ? '.' : '...'} ');
    }
    text.write(
      '${moves[ply % 4]} {Branch $branch move $ply. A wrapped course annotation with some explanatory prose.} ',
    );
  }
  return text.toString();
}
