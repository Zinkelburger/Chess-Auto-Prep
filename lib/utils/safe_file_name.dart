/// Cross-platform validation for a single user-visible filesystem component.
library;

/// Characters Windows rejects in a file component, plus ASCII controls.
final RegExp _illegalFileNameCharacters = RegExp(r'[<>:"/\\|?*\x00-\x1F]');

final RegExp _windowsDeviceName = RegExp(
  r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)',
  caseSensitive: false,
);

/// Returns a user-facing problem for [name], or `null` when it is a safe
/// single path component on Linux, macOS, and Windows.
String? validateSafeFileName(String name, {int maxLength = 120}) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return 'Please enter a name.';
  if (name.endsWith(' ')) return 'Names cannot end with a dot or space.';
  if (trimmed == '.' || trimmed == '..') return 'That name is reserved.';
  if (_illegalFileNameCharacters.hasMatch(trimmed)) {
    return r'Names cannot contain < > : " / \ | ? * or control characters.';
  }
  if (trimmed.endsWith('.')) {
    return 'Names cannot end with a dot or space.';
  }
  if (_windowsDeviceName.hasMatch(trimmed)) {
    return 'That name is reserved by the operating system.';
  }
  if (trimmed.length > maxLength) {
    return 'Names must be $maxLength characters or fewer.';
  }
  return null;
}

/// Returns [name] trimmed, or throws when it is not a safe path component.
String requireSafeFileName(String name, {int maxLength = 120}) {
  final problem = validateSafeFileName(name, maxLength: maxLength);
  if (problem != null) throw ArgumentError.value(name, 'name', problem);
  return name.trim();
}
