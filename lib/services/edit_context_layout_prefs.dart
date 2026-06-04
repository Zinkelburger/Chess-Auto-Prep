/// Persists [EditContextLayout] for the repertoire Edit context column.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/edit_context_layout.dart';

class EditContextLayoutPrefs {
  static const _keyLayout = 'edit_context.layout_v1';

  static Future<EditContextLayout> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_keyLayout);
      if (raw == null || raw.isEmpty) return EditContextLayout.defaultLayout;
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return EditContextLayout.fromJson(decoded);
    } catch (e) {
      debugPrint('[EditContextLayoutPrefs] load failed: $e');
      return EditContextLayout.defaultLayout;
    }
  }

  static Future<void> save(EditContextLayout layout) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyLayout, jsonEncode(layout.toJson()));
    } catch (e) {
      debugPrint('[EditContextLayoutPrefs] save failed: $e');
    }
  }
}
