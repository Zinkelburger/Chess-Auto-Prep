#include "desktop_integration.h"

#include <string.h>

// GTK3 clients cannot hand a Wayland compositor a window icon directly; the
// compositor resolves the icon by matching the window's app-id against an
// installed desktop entry. For portable builds nothing is installed, so we
// offer to copy a desktop entry and icon into the user's home. X11 keeps
// working through gtk_window_set_icon_from_file() regardless.
//
// The same desktop entry is what makes .pgn files open here: it claims the
// MIME type (so the app appears under "Open with"), and accepting the offer
// also writes it into mimeapps.list as the default handler.

static const char kPgnMimeType[] = "application/vnd.chess-pgn";
static const char kDesktopId[] = APPLICATION_ID ".desktop";

static gchar* state_dir() {
  return g_build_filename(g_get_user_data_dir(), "chess_auto_prep", nullptr);
}

// Records the answer to the current offer (menu entry + .pgn default).
static gchar* state_file_path() {
  g_autofree gchar* dir = state_dir();
  return g_build_filename(dir, "desktop-integration-choice", nullptr);
}

// The answer to the earlier, narrower offer (menu entry only).
static gchar* legacy_state_file_path() {
  g_autofree gchar* dir = state_dir();
  return g_build_filename(dir, "desktop-entry-choice", nullptr);
}

static void write_choice(const gchar* choice) {
  g_autofree gchar* path = state_file_path();
  g_autofree gchar* dir = g_path_get_dirname(path);
  g_mkdir_with_parents(dir, 0755);
  g_file_set_contents(path, choice, -1, nullptr);
}

static gchar* read_choice(const gchar* path) {
  gchar* choice = nullptr;
  if (!g_file_get_contents(path, &choice, nullptr, nullptr)) return nullptr;
  return choice;
}

static void write_file_if_changed(const gchar* path, const gchar* data,
                                  gssize length) {
  if (length < 0) length = strlen(data);
  gsize old_length = 0;
  g_autofree gchar* old_data = nullptr;
  if (g_file_get_contents(path, &old_data, &old_length, nullptr) &&
      old_length == (gsize)length && memcmp(old_data, data, old_length) == 0) {
    return;
  }
  g_autofree gchar* dir = g_path_get_dirname(path);
  g_mkdir_with_parents(dir, 0755);
  g_file_set_contents(path, data, length, nullptr);
}

// Rebuilds ~/.local/share/applications/mimeinfo.cache, which is what the
// "Open with" list is read from. Best effort: mimeapps.list (the default
// handler) is consulted directly and does not need it.
static void refresh_desktop_database(const gchar* applications_dir) {
  gchar* argv[] = {const_cast<gchar*>("update-desktop-database"),
                   const_cast<gchar*>(applications_dir), nullptr};
  g_spawn_async(nullptr, argv, nullptr,
                static_cast<GSpawnFlags>(G_SPAWN_SEARCH_PATH |
                                         G_SPAWN_STDOUT_TO_DEV_NULL |
                                         G_SPAWN_STDERR_TO_DEV_NULL),
                nullptr, nullptr, nullptr, nullptr);
}

static void install_menu_entry() {
  g_autofree gchar* exe_path = g_file_read_link("/proc/self/exe", nullptr);
  if (exe_path == nullptr) {
    return;
  }
  g_autofree gchar* exe_dir = g_path_get_dirname(exe_path);

  g_autofree gchar* icon_src = g_build_filename(
      exe_dir, "data", "flutter_assets", "assets", "images", "knook.png",
      nullptr);
  g_autofree gchar* icon_data = nullptr;
  gsize icon_length = 0;
  if (g_file_get_contents(icon_src, &icon_data, &icon_length, nullptr)) {
    g_autofree gchar* icon_dest = g_build_filename(
        g_get_user_data_dir(), "icons", "hicolor", "128x128", "apps",
        APPLICATION_ID ".png", nullptr);
    write_file_if_changed(icon_dest, icon_data, icon_length);
  }

  // Absolute Exec path, refreshed every launch so the entry keeps working
  // if the user moves the unzipped app folder. %f is the file the desktop
  // was asked to open with us.
  g_autofree gchar* exec_quoted = g_shell_quote(exe_path);
  g_autofree gchar* desktop_data = g_strdup_printf(
      "[Desktop Entry]\n"
      "Type=Application\n"
      "Name=Chess Auto Prep\n"
      "Comment=Chess repertoire and tactics trainer\n"
      "Exec=%s %%f\n"
      "Icon=" APPLICATION_ID "\n"
      "StartupWMClass=" APPLICATION_ID "\n"
      "Categories=Game;BoardGame;\n"
      "Keywords=chess;pgn;repertoire;tactics;\n"
      "MimeType=%s;\n",
      exec_quoted, kPgnMimeType);
  g_autofree gchar* applications_dir =
      g_build_filename(g_get_user_data_dir(), "applications", nullptr);
  g_autofree gchar* desktop_dest =
      g_build_filename(applications_dir, kDesktopId, nullptr);
  write_file_if_changed(desktop_dest, desktop_data, -1);
  refresh_desktop_database(applications_dir);
}

// Prepends |entry| to the ';'-separated list in |group|/|key| unless present.
static void key_file_add_to_list(GKeyFile* key_file, const gchar* group,
                                 const gchar* key, const gchar* entry) {
  g_autofree gchar* current =
      g_key_file_get_string(key_file, group, key, nullptr);
  if (current != nullptr) {
    g_auto(GStrv) parts = g_strsplit(current, ";", -1);
    for (gchar** part = parts; *part != nullptr; ++part) {
      if (g_strcmp0(*part, entry) == 0) return;
    }
  }
  g_autofree gchar* updated =
      (current == nullptr || *current == '\0')
          ? g_strdup_printf("%s;", entry)
          : g_strdup_printf("%s;%s", entry, current);
  g_key_file_set_string(key_file, group, key, updated);
}

// Makes this app the default for .pgn in the user's mimeapps.list — the file
// `xdg-mime default` edits, written directly so xdg-utils is not required.
// Done once, on accepting the offer: re-asserting it on every launch would
// silently undo a default the user later changed.
static void set_default_pgn_handler() {
  g_autofree gchar* path =
      g_build_filename(g_get_user_config_dir(), "mimeapps.list", nullptr);
  g_autoptr(GKeyFile) key_file = g_key_file_new();
  g_key_file_load_from_file(key_file, path, G_KEY_FILE_KEEP_COMMENTS, nullptr);

  g_key_file_set_string(key_file, "Default Applications", kPgnMimeType,
                        kDesktopId);
  key_file_add_to_list(key_file, "Added Associations", kPgnMimeType,
                       kDesktopId);

  g_autofree gchar* dir = g_path_get_dirname(path);
  g_mkdir_with_parents(dir, 0755);
  g_autoptr(GError) error = nullptr;
  if (!g_key_file_save_to_file(key_file, path, &error)) {
    g_warning("Could not update %s: %s", path, error->message);
  }
}

static void on_prompt_response(GtkDialog* dialog, gint response_id,
                               gpointer user_data) {
  if (response_id == GTK_RESPONSE_ACCEPT) {
    write_choice("yes");
    install_menu_entry();
    set_default_pgn_handler();
  } else if (response_id == GTK_RESPONSE_REJECT) {
    write_choice("no");
  }
  // Closing the dialog without choosing leaves no state, so we ask again
  // on the next launch.
  gtk_widget_destroy(GTK_WIDGET(dialog));
}

void desktop_integration_maybe_setup(GtkWindow* parent_window) {
  if (g_file_test("/.flatpak-info", G_FILE_TEST_EXISTS)) {
    return;
  }

  g_autofree gchar* path = state_file_path();
  g_autofree gchar* choice = read_choice(path);
  if (choice != nullptr) {
    if (g_str_has_prefix(choice, "yes")) {
      install_menu_entry();
    }
    return;
  }

  // Someone who declined the menu entry has said no to this once already;
  // someone who accepted it keeps it, and is asked once about .pgn files.
  g_autofree gchar* legacy_path = legacy_state_file_path();
  g_autofree gchar* legacy_choice = read_choice(legacy_path);
  if (legacy_choice != nullptr) {
    if (g_str_has_prefix(legacy_choice, "no")) {
      write_choice("no");
      return;
    }
    install_menu_entry();
  }

  GtkWidget* dialog = gtk_message_dialog_new(
      parent_window, GTK_DIALOG_MODAL, GTK_MESSAGE_QUESTION, GTK_BUTTONS_NONE,
      "Set up Chess Auto Prep on this desktop?");
  gtk_message_dialog_format_secondary_text(
      GTK_MESSAGE_DIALOG(dialog),
      "Adds it to your app menu with its icon and makes it the default app "
      "for .pgn files. This only writes files in your home folder; you can "
      "change the default later in your desktop's settings.");
  gtk_dialog_add_button(GTK_DIALOG(dialog), "No Thanks", GTK_RESPONSE_REJECT);
  gtk_dialog_add_button(GTK_DIALOG(dialog), "Set Up", GTK_RESPONSE_ACCEPT);
  gtk_dialog_set_default_response(GTK_DIALOG(dialog), GTK_RESPONSE_ACCEPT);
  g_signal_connect(dialog, "response", G_CALLBACK(on_prompt_response),
                   nullptr);
  gtk_widget_show_all(dialog);
}
