/**
 * progress_line.c - In-place terminal progress line updates
 */

#include "progress_line.h"

#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>

static bool g_is_tty;
static int g_rows_used;

void progress_line_init(void) {
    g_is_tty = isatty(STDOUT_FILENO) != 0;
    g_rows_used = 0;
}

bool progress_line_is_tty(void) {
    return g_is_tty;
}

static int terminal_cols(void) {
    struct winsize ws;
    if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0)
        return (int)ws.ws_col;
    return 80;
}

static void cursor_up(int rows) {
    for (int i = 0; i < rows; i++)
        fputs("\033[A", stdout);
}

void progress_line_update(const char *text) {
    if (!text)
        text = "";

    if (!g_is_tty)
        return;

    cursor_up(g_rows_used - 1);
    fputs("\r\033[2K", stdout);
    fputs(text, stdout);

    int cols = terminal_cols();
    size_t len = strlen(text);
    g_rows_used = (int)((len + (size_t)cols - 1) / (size_t)cols);
    if (g_rows_used < 1)
        g_rows_used = 1;

    fflush(stdout);
}

void progress_line_clear(void) {
    if (!g_is_tty)
        return;

    cursor_up(g_rows_used - 1);
    fputs("\r\033[2K", stdout);
    g_rows_used = 0;
    fflush(stdout);
}
