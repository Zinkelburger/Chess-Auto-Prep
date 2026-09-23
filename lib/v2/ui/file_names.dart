/// What a file or folder may be called.
///
/// One rule for every name the user gives something that becomes a file: the
/// dialog shows it before the name leaves the field, and the owner that
/// writes the file checks it again, because a name can also arrive from a
/// download or another mode without passing a dialog at all. Pure Dart, so
/// both sides can have it.
library;

/// The longest name a file may be given. Every desktop filesystem this app
/// runs on allows more; 120 is what the old app settled on, and a name a
/// column cannot show is not a name anyone wants.
const maxNameLength = 120;

final _illegalCharacters = RegExp(r'[<>:"/\\|?*\x00-\x1F]');

/// `CON`, `PRN.txt` and friends: names Windows gives to devices, which no
/// file may take even on the drive where this app is storing them.
final _deviceName = RegExp(
  r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)',
  caseSensitive: false,
);

/// What is wrong with [name] as a file or folder name, or null when nothing
/// is. A name has to work on every platform the user's Documents folder might
/// be synced to, so Windows' rules apply on Linux too.
String? nameProblem(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return 'Please enter a name.';
  // Untrimmed: the name dialog trims what it answers, but a name can reach
  // an owner from a download or another mode with a space still at its end,
  // which not every filesystem keeps.
  if (name.endsWith(' ')) return 'Names cannot end with a dot or space.';
  if (trimmed == '.' || trimmed == '..') return 'That name is reserved.';
  // A folder whose name starts with a dot is hidden, by this app's own
  // listing and by every file manager, so the user would be making something
  // they could never open again.
  if (trimmed.startsWith('.')) {
    return 'Names cannot start with a dot; the list would not show it.';
  }
  if (_illegalCharacters.hasMatch(trimmed)) {
    return r'Names cannot contain < > : " / \ | ? * or control characters.';
  }
  if (trimmed.endsWith('.')) return 'Names cannot end with a dot or space.';
  if (_deviceName.hasMatch(trimmed)) {
    return 'That name is reserved by the operating system.';
  }
  if (trimmed.length > maxNameLength) {
    return 'Names must be $maxNameLength characters or fewer.';
  }
  return null;
}

/// [name] with the characters a file cannot take replaced, for a name this
/// app made up rather than one the user typed — the title of a downloaded
/// study, say. A name left with nothing in it becomes [fallback].
///
/// Refusing is right for a name the user can correct; a download has nobody
/// to ask, and nothing here can make a path out of a name: separators, dot
/// segments and control characters all go.
String safeFileName(String name, {required String fallback}) {
  final safe = name
      .replaceAll(_illegalCharacters, '_')
      .replaceAll('.', '_')
      .trim();
  return nameProblem(safe) == null ? safe : fallback;
}

/// The longest name an import gives a folder or file, which is what the old
/// app allowed for a name it made up from a file's.
const maxImportedNameLength = 100;

/// A name for something the user did not name — the repertoire made from a
/// file, the chapter made from a course title — made safe to be a file:
/// the characters a file cannot take become `_`, a leading dot and trailing
/// dots and spaces go, and it is cut to [maxImportedNameLength]. What is
/// left with nothing in it, or a name the operating system reserves, is
/// [fallback].
///
/// Dots inside the name stay: `6.Bg5 e6` is a chapter title, not a path.
String importedName(String name, {required String fallback}) {
  var safe = name.replaceAll(_illegalCharacters, '_').trim();
  safe = safe.replaceFirst(RegExp(r'^\.+'), '');
  if (safe.length > maxImportedNameLength) {
    safe = safe.substring(0, maxImportedNameLength);
  }
  safe = safe.replaceFirst(RegExp(r'[. ]+$'), '');
  return nameProblem(safe) == null ? safe : fallback;
}
