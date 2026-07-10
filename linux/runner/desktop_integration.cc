#include "desktop_integration.h"

#include <string.h>

// GTK3 clients cannot hand a Wayland compositor a window icon directly; the
// compositor resolves the icon by matching the window's app-id against an
// installed desktop entry. For portable builds nothing is installed, so we
// offer to copy a desktop entry and icon into the user's home. X11 keeps
// working through gtk_window_set_icon_from_file() regardless.

static gchar* state_file_path() {
  return g_build_filename(g_get_user_data_dir(), "chess_auto_prep",
                          "desktop-entry-choice", nullptr);
}

static void write_choice(const gchar* choice) {
  g_autofree gchar* path = state_file_path();
  g_autofree gchar* dir = g_path_get_dirname(path);
  g_mkdir_with_parents(dir, 0755);
  g_file_set_contents(path, choice, -1, nullptr);
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
  // if the user moves the unzipped app folder.
  g_autofree gchar* exec_quoted = g_shell_quote(exe_path);
  g_autofree gchar* desktop_data = g_strdup_printf(
      "[Desktop Entry]\n"
      "Type=Application\n"
      "Name=Chess Auto Prep\n"
      "Comment=Chess repertoire and tactics trainer\n"
      "Exec=%s\n"
      "Icon=" APPLICATION_ID "\n"
      "StartupWMClass=" APPLICATION_ID "\n"
      "Categories=Game;Education;\n",
      exec_quoted);
  g_autofree gchar* desktop_dest =
      g_build_filename(g_get_user_data_dir(), "applications",
                       APPLICATION_ID ".desktop", nullptr);
  write_file_if_changed(desktop_dest, desktop_data, -1);
}

static void on_prompt_response(GtkDialog* dialog, gint response_id,
                               gpointer user_data) {
  if (response_id == GTK_RESPONSE_ACCEPT) {
    write_choice("yes");
    install_menu_entry();
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
  g_autofree gchar* choice = nullptr;
  if (g_file_get_contents(path, &choice, nullptr, nullptr)) {
    if (g_str_has_prefix(choice, "yes")) {
      install_menu_entry();
    }
    return;
  }

  GtkWidget* dialog = gtk_message_dialog_new(
      parent_window, GTK_DIALOG_MODAL, GTK_MESSAGE_QUESTION, GTK_BUTTONS_NONE,
      "Add Chess Auto Prep to your app menu?");
  gtk_message_dialog_format_secondary_text(
      GTK_MESSAGE_DIALOG(dialog),
      "This lets your desktop show the app's icon and launch it from the "
      "menu. It only copies a menu entry and an icon into your home folder, "
      "and you can undo it anytime by removing the menu entry.");
  gtk_dialog_add_button(GTK_DIALOG(dialog), "No Thanks", GTK_RESPONSE_REJECT);
  gtk_dialog_add_button(GTK_DIALOG(dialog), "Add to Menu",
                        GTK_RESPONSE_ACCEPT);
  gtk_dialog_set_default_response(GTK_DIALOG(dialog), GTK_RESPONSE_ACCEPT);
  g_signal_connect(dialog, "response", G_CALLBACK(on_prompt_response),
                   nullptr);
  gtk_widget_show_all(dialog);
}
