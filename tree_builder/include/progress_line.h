/**
 * progress_line.h - In-place terminal progress line updates
 *
 * Uses carriage return + ANSI erase so a single status line can be
 * refreshed without flooding the terminal.  Handles line-wrapping by
 * moving the cursor up before each rewrite.
 */

#ifndef PROGRESS_LINE_H
#define PROGRESS_LINE_H

#include <stdbool.h>

void progress_line_init(void);
bool progress_line_is_tty(void);
void progress_line_update(const char *text);
void progress_line_clear(void);

#endif /* PROGRESS_LINE_H */
