import 'dart:html' as html;

class PlatformStorage {
  static void saveToLocalStorage(String key, String content) {
    html.window.localStorage[key] = content;
  }

  static String? loadFromLocalStorage(String key) {
    return html.window.localStorage[key];
  }
}