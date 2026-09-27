/// SAN matching for the Games feature's opening review.
///
/// Reading the mainline off a downloaded game is `mainlineSansOf` in
/// `chess_core/pgn/mainline_lexer.dart` — the shared lexer that is pinned
/// against dartchess — not a second parser here.
library;

/// SAN with check/mate suffixes removed, for tolerance-matched comparison
/// ("Nf3+" in a game must hit "Nf3" in a repertoire and vice versa).
String normalizeSan(String san) => san.replaceAll(RegExp(r'[+#]+$'), '');
