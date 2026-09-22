/// Cross-platform validation for a single user-visible filesystem component.
library;

/// Characters Windows rejects in a file component, plus ASCII controls.
final RegExp _illegalFileNameCharacters = RegExp(r'[<>:"/\\|?*\x00-\x1F]');

final RegExp _windowsDeviceName = RegExp(
  r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)',
  caseSensitive: false,
);

enum FileNameProblem {
  empty,
  trailingDotOrSpace,
  reserved,
  illegalCharacters,
  systemReserved,
  tooLong,
}

/// Locale-independent validation; presentation chooses the message.
FileNameProblem? fileNameProblem(String name, {int maxLength = 120}) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return FileNameProblem.empty;
  if (name.endsWith(' ')) return FileNameProblem.trailingDotOrSpace;
  if (trimmed == '.' || trimmed == '..') return FileNameProblem.reserved;
  if (_illegalFileNameCharacters.hasMatch(trimmed)) {
    return FileNameProblem.illegalCharacters;
  }
  if (trimmed.endsWith('.')) return FileNameProblem.trailingDotOrSpace;
  if (_windowsDeviceName.hasMatch(trimmed)) {
    return FileNameProblem.systemReserved;
  }
  if (trimmed.length > maxLength) return FileNameProblem.tooLong;
  return null;
}

/// English adapter for legacy callers. Migrated UI resolves [fileNameProblem]
/// through its localized messages; storage depends only on validation.
String? validateSafeFileName(
  String name, {
  int maxLength = 120,
}) => switch (fileNameProblem(name, maxLength: maxLength)) {
  null => null,
  FileNameProblem.empty => 'Please enter a name.',
  FileNameProblem.trailingDotOrSpace => 'Names cannot end with a dot or space.',
  FileNameProblem.reserved => 'That name is reserved.',
  FileNameProblem.illegalCharacters =>
    r'Names cannot contain < > : " / \ | ? * or control characters.',
  FileNameProblem.systemReserved =>
    'That name is reserved by the operating system.',
  FileNameProblem.tooLong => 'Names must be $maxLength characters or fewer.',
};

/// Returns [name] trimmed, or throws when it is not a safe path component.
String requireSafeFileName(String name, {int maxLength = 120}) {
  final problem = validateSafeFileName(name, maxLength: maxLength);
  if (problem != null) throw ArgumentError.value(name, 'name', problem);
  return name.trim();
}
