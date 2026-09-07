/// Chessable exports sometimes remove the spaces around numbered moves in
/// prose (`against1.e4and`, `5...Be7`). Repair that only for display; the
/// PGN bytes and comment editor remain untouched.
String normalizeCourseCommentSpacing(String text) {
  // Only a number that a move follows is a move number: "at c3." ends a
  // sentence with a square, and must not become "c 3.".
  var result = text.replaceAllMapped(
    RegExp(r'([A-Za-z,;:!?])(\d+\.{1,3})(?=[KQRBNOa-h])'),
    (m) => '${m[1]} ${m[2]}',
  );
  final numberedSan = RegExp(
    r'(\d+\.{1,3}(?:O-O-O|O-O|(?:[KQRBN][a-h1-8]?x?[a-h][1-8]|[a-h]x[a-h][1-8]|[a-h][1-8])(?:=[QRBN])?)[+#?!]*)(?=[A-Za-z])',
  );
  result = result.replaceAllMapped(numberedSan, (m) => '${m[1]} ');
  result = result.replaceAllMapped(
    RegExp(r'([+#])(?=[KQRBNOa-h])'),
    (m) => '${m[1]} ',
  );
  return result.trim();
}
