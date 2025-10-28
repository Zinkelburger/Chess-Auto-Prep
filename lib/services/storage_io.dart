class PlatformStorage {
  static void saveToLocalStorage(String key, String content) {
    // No-op on non-web platforms
  }

  static String? loadFromLocalStorage(String key) {
    // No-op on non-web platforms
    return null;
  }
}