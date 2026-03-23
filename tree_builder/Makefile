# Makefile for Chess Repertoire Builder
#
# Dependencies:
#   - libcurl  (HTTP requests to Lichess API)
#   - sqlite3  (persistent caching database)
#   - pthreads (multithreaded engine pool)
#   - cJSON    (included in src/)
#
# Install dependencies (Fedora):
#   sudo dnf install libcurl-devel sqlite-devel
#
# Install dependencies (Ubuntu/Debian):
#   sudo apt install libcurl4-openssl-dev libsqlite3-dev

CC = gcc
CFLAGS = -Wall -Wextra -std=gnu11 -O2 -g
LDFLAGS = -lm -lpthread -ldl

# Local includes for headers that may not be system-installed
# curl headers: downloaded to local_includes/curl/
# sqlite3: using amalgamation in src/
LOCAL_INC = -Ilocal_includes
LOCAL_LIB = -Llocal_lib

# Check for libcurl via pkg-config; fall back to direct link
CURL_CHECK := $(shell pkg-config --exists libcurl 2>/dev/null && echo yes || echo no)
ifeq ($(CURL_CHECK),yes)
    CFLAGS += $(shell pkg-config --cflags libcurl)
    LDFLAGS += $(shell pkg-config --libs libcurl)
else
    # Try libcurl-minimal (common on Fedora)
    LDFLAGS += -lcurl
endif

# SQLite3: use amalgamation (compiled into the binary directly)
# This means no external sqlite3-devel dependency needed.
CFLAGS += -DSQLITE_THREADSAFE=1 -DSQLITE_OMIT_LOAD_EXTENSION

# Directories
SRC_DIR = src
INC_DIR = include
BUILD_DIR = build
BIN_DIR = bin

# Source files
SRCS = $(SRC_DIR)/node.c \
       $(SRC_DIR)/tree.c \
       $(SRC_DIR)/lichess_api.c \
       $(SRC_DIR)/serialization.c \
       $(SRC_DIR)/chess_logic.c \
       $(SRC_DIR)/thread_pool.c \
       $(SRC_DIR)/database.c \
       $(SRC_DIR)/engine_pool.c \
       $(SRC_DIR)/repertoire.c \
       $(SRC_DIR)/sqlite3_amalg.c \
       $(SRC_DIR)/cJSON.c \
       $(SRC_DIR)/main.c

# Object files
OBJS = $(patsubst $(SRC_DIR)/%.c,$(BUILD_DIR)/%.o,$(SRCS))

# Target executable
TARGET = $(BIN_DIR)/tree_builder

# Include paths
INCLUDES = -I$(INC_DIR) -I$(SRC_DIR) $(LOCAL_INC)

.PHONY: all clean install test help check-deps

all: check-deps directories $(TARGET)

directories:
	@mkdir -p $(BUILD_DIR)
	@mkdir -p $(BIN_DIR)

$(TARGET): $(OBJS)
	$(CC) $(OBJS) -o $@ $(LOCAL_LIB) $(LDFLAGS)
	@echo ""
	@echo "══════════════════════════════════════════"
	@echo "  Build complete: $(TARGET)"
	@echo "══════════════════════════════════════════"
	@echo ""

$(BUILD_DIR)/%.o: $(SRC_DIR)/%.c
	$(CC) $(CFLAGS) $(INCLUDES) -c $< -o $@

# SQLite3 amalgamation: suppress all warnings (third-party code)
$(BUILD_DIR)/sqlite3_amalg.o: $(SRC_DIR)/sqlite3_amalg.c
	$(CC) -std=gnu11 -O2 -g -w $(INCLUDES) -DSQLITE_THREADSAFE=1 -DSQLITE_OMIT_LOAD_EXTENSION -c $< -o $@

# Header dependencies
$(BUILD_DIR)/node.o: $(INC_DIR)/node.h
$(BUILD_DIR)/tree.o: $(INC_DIR)/tree.h $(INC_DIR)/node.h $(INC_DIR)/lichess_api.h $(INC_DIR)/chess_logic.h
$(BUILD_DIR)/lichess_api.o: $(INC_DIR)/lichess_api.h $(SRC_DIR)/cJSON.h
$(BUILD_DIR)/serialization.o: $(INC_DIR)/serialization.h $(INC_DIR)/tree.h $(SRC_DIR)/cJSON.h
$(BUILD_DIR)/chess_logic.o: $(INC_DIR)/chess_logic.h
$(BUILD_DIR)/thread_pool.o: $(INC_DIR)/thread_pool.h
$(BUILD_DIR)/database.o: $(INC_DIR)/database.h
$(BUILD_DIR)/engine_pool.o: $(INC_DIR)/engine_pool.h $(INC_DIR)/thread_pool.h
$(BUILD_DIR)/repertoire.o: $(INC_DIR)/repertoire.h $(INC_DIR)/tree.h $(INC_DIR)/database.h $(INC_DIR)/engine_pool.h $(INC_DIR)/chess_logic.h $(SRC_DIR)/cJSON.h
$(BUILD_DIR)/main.o: $(INC_DIR)/tree.h $(INC_DIR)/lichess_api.h $(INC_DIR)/serialization.h $(INC_DIR)/database.h $(INC_DIR)/engine_pool.h $(INC_DIR)/repertoire.h $(INC_DIR)/chess_logic.h

clean:
	rm -rf $(BUILD_DIR) $(BIN_DIR)
	@echo "Clean complete"

# Check dependencies
check-deps:
	@echo "Checking dependencies..."
ifeq ($(CURL_CHECK),no)
	@echo "  WARNING: libcurl not found via pkg-config, trying direct link"
endif
ifeq ($(SQLITE_CHECK),no)
	@echo "  WARNING: sqlite3 not found via pkg-config, trying direct link"
	@echo "  Install with: sudo dnf install sqlite-devel (Fedora)"
	@echo "            or: sudo apt install libsqlite3-dev (Debian/Ubuntu)"
endif
	@echo "  Dependencies OK"

# Install to /usr/local/bin
install: $(TARGET)
	install -m 755 $(TARGET) /usr/local/bin/tree_builder
	@echo "Installed to /usr/local/bin/tree_builder"

# Quick test run (small tree)
test: $(TARGET)
	@echo ""
	@echo "Running quick test (depth 4, probability 5%)..."
	@echo ""
	$(TARGET) -v -p 0.05 -d 4 -e 15 --skip-eval test_output.json
	@echo ""
	@echo "Test output saved to test_output.json"
	@rm -f test_output.json repertoire.db

# Full test with engine
test-full: $(TARGET)
	@echo ""
	@echo "Running full test with Stockfish (depth 6, 2 engines)..."
	$(TARGET) -v -c w -p 0.01 -d 6 -e 20 -t 2 --traps --pgn test.pgn test_output.json
	@echo ""
	@rm -f test_output.json test_output.json.repertoire.json test.pgn repertoire.db

# Help
help:
	@echo ""
	@echo "Chess Repertoire Builder - Makefile"
	@echo ""
	@echo "Targets:"
	@echo "  all        - Build the tree_builder executable (default)"
	@echo "  clean      - Remove build artifacts"
	@echo "  install    - Install to /usr/local/bin"
	@echo "  test       - Quick test (no engine)"
	@echo "  test-full  - Full test with Stockfish"
	@echo "  check-deps - Check for required libraries"
	@echo "  help       - Show this help"
	@echo ""
	@echo "Dependencies (install first):"
	@echo "  Fedora:  sudo dnf install libcurl-devel sqlite-devel gcc"
	@echo "  Ubuntu:  sudo apt install libcurl4-openssl-dev libsqlite3-dev gcc"
	@echo ""
	@echo "After building:"
	@echo "  ./bin/tree_builder -h      (show usage)"
	@echo "  ./bin/tree_builder -v -c w repertoire.json"
	@echo ""
