import 'package:shared_preferences/shared_preferences.dart';

import '../diagnostics/log.dart';

/// Where the Lichess access token is kept.
///
/// The same SharedPreferences key the old app writes when the user signs in,
/// so both apps see one account and `v2` never asks the user to sign in
/// again. The token is only ever handed to the client that puts it in an
/// `Authorization` header; it is never logged, and a failure here says only
/// that the key could not be read.
const lichessTokenKey = 'lichess_access_token';

/// The user's Lichess token, or null when they have not signed in — and also
/// when the preferences could not be read, because a study download without
/// a token still works for a public study, and the failure is named in the
/// log either way.
Future<String?> readLichessToken() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString(lichessTokenKey);
    return token == null || token.isEmpty ? null : token;
  } on Object catch (error) {
    log.w('read the saved Lichess account', error);
    return null;
  }
}
