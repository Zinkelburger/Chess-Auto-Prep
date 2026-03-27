# Makefile for Chess Repertoire Builder
#
# Dependencies:
#   - libcurl  (HTTP requests to Lichess API)
#   - sqlite3  (bundled amalgamation — no external package needed)
#   - pthreads (multithreaded engine pool)
#   - cJSON    (bundled in src/)
#
# Optional (for Maia neural-network fallback):
#   - ONNX Runtime C API  (build with: make MAIA=1)
#
# Install dependencies (Fedora):
#   sudo dnf install libcurl-devel gcc make
#
# Install dependencies (Ubuntu/Debian):
#   sudo apt install libcurl4-openssl-dev gcc make

CC = gcc
CFLAGS = -Wall -Wextra -std=gnu11 -O2 -g
LDFLAGS = -lm -lpthread -ldl

# Local includes for headers that may not be system-installed
#   curl headers      → local_includes/curl/
#   onnxruntime header → local_includes/onnxruntime_c_api.h
#   sqlite3           → amalgamation in src/
LOCAL_INC = -Ilocal_includes

# Only add -Llocal_lib if the directory exists (for local overrides)
LOCAL_LIB = $(if $(wildcard local_lib),-Llocal_lib)

# Check for libcurl via pkg-config; fall back to direct link
CURL_CHECK := $(shell pkg-config --exists libcurl 2>/dev/null && echo yes || echo no)
ifeq ($(CURL_CHECK),yes)
    CFLAGS += $(shell pkg-config --cflags libcurl)
    LDFLAGS += $(shell pkg-config --libs libcurl)
else
    LDFLAGS += -lcurl
endif

# SQLite3: use amalgamation (compiled into the binary directly)
CFLAGS += -DSQLITE_THREADSAFE=1 -DSQLITE_OMIT_LOAD_EXTENSION

# chesslib (third-party, BSD-2-Clause) — used by Maia for legal move generation
CHESSLIB_DIR = third_party/chesslib

# Optional: Maia neural-network fallback (make MAIA=1)
# Requires ONNX Runtime: the header is bundled in local_includes/,
# but the shared library must be installed on the system.
#   Fedora:  sudo dnf install onnxruntime-devel
#   Ubuntu:  see https://github.com/microsoft/onnxruntime
#   pip:     pip install onnxruntime  (then set LD_LIBRARY_PATH)
ifdef MAIA
    CFLAGS += -DHAVE_ONNXRUNTIME
    ORT_CHECK := $(shell pkg-config --exists libonnxruntime 2>/dev/null && echo yes || echo no)
    ifeq ($(ORT_CHECK),yes)
        CFLAGS += $(shell pkg-config --cflags libonnxruntime)
        LDFLAGS += $(shell pkg-config --libs libonnxruntime)
    else
        LDFLAGS += -lonnxruntime
    endif
endif

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
       $(SRC_DIR)/maia.c \
       $(SRC_DIR)/sqlite3_amalg.c \
       $(SRC_DIR)/cJSON.c \
       $(SRC_DIR)/main.c

# chesslib sources (third-party)
CHESSLIB_SRCS = $(CHESSLIB_DIR)/chess.c \
                $(CHESSLIB_DIR)/move.c \
                $(CHESSLIB_DIR)/unmove.c \
                $(CHESSLIB_DIR)/position.c \
                $(CHESSLIB_DIR)/fen.c \
                $(CHESSLIB_DIR)/generate.c \
                $(CHESSLIB_DIR)/carray.c \
                $(CHESSLIB_DIR)/calloc.c

# Object files
OBJS = $(patsubst $(SRC_DIR)/%.c,$(BUILD_DIR)/%.o,$(SRCS)) \
       $(patsubst $(CHESSLIB_DIR)/%.c,$(BUILD_DIR)/chesslib_%.o,$(CHESSLIB_SRCS))

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

# chesslib (third-party): suppress warnings
$(BUILD_DIR)/chesslib_%.o: $(CHESSLIB_DIR)/%.c
	$(CC) -std=gnu11 -O2 -g -w -I$(CHESSLIB_DIR) -c $< -o $@

# SQLite3 amalgamation: suppress all warnings (third-party code)
$(BUILD_DIR)/sqlite3_amalg.o: $(SRC_DIR)/sqlite3_amalg.c
	$(CC) -std=gnu11 -O2 -g -w $(INCLUDES) -DSQLITE_THREADSAFE=1 -DSQLITE_OMIT_LOAD_EXTENSION -c $< -o $@

# Header dependencies
$(BUILD_DIR)/node.o: $(INC_DIR)/node.h
$(BUILD_DIR)/tree.o: $(INC_DIR)/tree.h $(INC_DIR)/node.h $(INC_DIR)/lichess_api.h $(INC_DIR)/chess_logic.h $(INC_DIR)/maia.h $(INC_DIR)/engine_pool.h $(INC_DIR)/database.h $(INC_DIR)/repertoire.h
$(BUILD_DIR)/lichess_api.o: $(INC_DIR)/lichess_api.h $(SRC_DIR)/cJSON.h
$(BUILD_DIR)/serialization.o: $(INC_DIR)/serialization.h $(INC_DIR)/tree.h $(SRC_DIR)/cJSON.h
$(BUILD_DIR)/chess_logic.o: $(INC_DIR)/chess_logic.h
$(BUILD_DIR)/thread_pool.o: $(INC_DIR)/thread_pool.h
$(BUILD_DIR)/database.o: $(INC_DIR)/database.h
$(BUILD_DIR)/engine_pool.o: $(INC_DIR)/engine_pool.h $(INC_DIR)/thread_pool.h
$(BUILD_DIR)/repertoire.o: $(INC_DIR)/repertoire.h $(INC_DIR)/tree.h $(INC_DIR)/database.h $(INC_DIR)/engine_pool.h $(INC_DIR)/chess_logic.h $(SRC_DIR)/cJSON.h
$(BUILD_DIR)/maia.o: $(INC_DIR)/maia.h $(INC_DIR)/chess_logic.h $(SRC_DIR)/maia_vocab.inc
$(BUILD_DIR)/main.o: $(INC_DIR)/tree.h $(INC_DIR)/lichess_api.h $(INC_DIR)/serialization.h $(INC_DIR)/database.h $(INC_DIR)/engine_pool.h $(INC_DIR)/repertoire.h $(INC_DIR)/chess_logic.h $(INC_DIR)/maia.h

clean:
	rm -rf $(BUILD_DIR) $(BIN_DIR)
	@echo "Clean complete"

# Check dependencies
check-deps:
	@echo "Checking dependencies..."
ifeq ($(CURL_CHECK),no)
	@echo "  WARNING: libcurl not found via pkg-config, trying direct link"
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
	@echo "  Fedora:  sudo dnf install libcurl-devel gcc make"
	@echo "  Ubuntu:  sudo apt install libcurl4-openssl-dev gcc make"
	@echo ""
	@echo "Optional (Maia neural-network support):"
	@echo "  make MAIA=1"
	@echo "  Requires ONNX Runtime shared library:"
	@echo "    Fedora:  sudo dnf install onnxruntime-devel"
	@echo "    pip:     pip install onnxruntime (set LD_LIBRARY_PATH)"
	@echo ""
	@echo "After building:"
	@echo "  ./bin/tree_builder -h      (show usage)"
	@echo "  ./bin/tree_builder -v -c w repertoire.json"
	@echo ""
