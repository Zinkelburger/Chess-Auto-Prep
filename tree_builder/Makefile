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
LDFLAGS = -lm -lpthread -ldl -Wl,-rpath,'$$ORIGIN'

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

# Maia neural-network fallback (enabled by default).
# Requires ONNX Runtime: the header is bundled in local_includes/,
# but the shared library must be installed on the system.
#   Fedora:  sudo dnf install onnxruntime-devel
#   Ubuntu:  see https://github.com/microsoft/onnxruntime
#   pip:     pip install onnxruntime  (then set LD_LIBRARY_PATH)
# To disable: make NO_MAIA=1
ifndef NO_MAIA
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
       $(SRC_DIR)/lichess_eval_db.c \
       $(SRC_DIR)/serialization.c \
       $(SRC_DIR)/chess_logic.c \
       $(SRC_DIR)/san_convert.c \
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

# Standalone ETL tool: lichess_db_eval.jsonl -> slim SQLite
ETL_TARGET = $(BIN_DIR)/build_lichess_eval_db
ETL_OBJS = $(BUILD_DIR)/build_lichess_eval_db.o \
           $(BUILD_DIR)/sqlite3_amalg.o \
           $(BUILD_DIR)/cJSON.o

# Include paths
INCLUDES = -I$(INC_DIR) -I$(SRC_DIR) $(LOCAL_INC)

.PHONY: all clean install test help check-deps dist etl

all: check-deps directories $(TARGET)

etl: directories $(ETL_TARGET)

$(ETL_TARGET): $(ETL_OBJS)
	$(CC) $(ETL_OBJS) -o $@ -lm -lpthread -ldl
	@echo ""
	@echo "══════════════════════════════════════════"
	@echo "  Build complete: $(ETL_TARGET)"
	@echo "══════════════════════════════════════════"
	@echo ""

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
$(BUILD_DIR)/tree.o: $(INC_DIR)/tree.h $(INC_DIR)/node.h $(INC_DIR)/lichess_api.h $(INC_DIR)/chess_logic.h $(INC_DIR)/san_convert.h $(INC_DIR)/maia.h $(INC_DIR)/engine_pool.h $(INC_DIR)/database.h $(INC_DIR)/repertoire.h $(INC_DIR)/lichess_eval_db.h
$(BUILD_DIR)/lichess_api.o: $(INC_DIR)/lichess_api.h $(SRC_DIR)/cJSON.h
$(BUILD_DIR)/lichess_eval_db.o: $(INC_DIR)/lichess_eval_db.h
$(BUILD_DIR)/serialization.o: $(INC_DIR)/serialization.h $(INC_DIR)/tree.h $(SRC_DIR)/cJSON.h
$(BUILD_DIR)/chess_logic.o: $(INC_DIR)/chess_logic.h
# san_convert uses chesslib types (separate TU to avoid ChessPosition name clash)
$(BUILD_DIR)/san_convert.o: $(SRC_DIR)/san_convert.c $(INC_DIR)/san_convert.h
	$(CC) $(CFLAGS) $(INCLUDES) -I$(CHESSLIB_DIR) -c $< -o $@
$(BUILD_DIR)/thread_pool.o: $(INC_DIR)/thread_pool.h
$(BUILD_DIR)/database.o: $(INC_DIR)/database.h
$(BUILD_DIR)/engine_pool.o: $(INC_DIR)/engine_pool.h $(INC_DIR)/thread_pool.h
$(BUILD_DIR)/repertoire.o: $(INC_DIR)/repertoire.h $(INC_DIR)/tree.h $(INC_DIR)/database.h $(INC_DIR)/engine_pool.h $(INC_DIR)/chess_logic.h $(SRC_DIR)/cJSON.h
$(BUILD_DIR)/maia.o: $(INC_DIR)/maia.h $(INC_DIR)/chess_logic.h $(SRC_DIR)/maia_vocab.inc
$(BUILD_DIR)/main.o: $(INC_DIR)/tree.h $(INC_DIR)/lichess_api.h $(INC_DIR)/serialization.h $(INC_DIR)/database.h $(INC_DIR)/engine_pool.h $(INC_DIR)/repertoire.h $(INC_DIR)/chess_logic.h $(INC_DIR)/maia.h $(INC_DIR)/lichess_eval_db.h

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

# Quick offline smoke test (only our first move, so no API/Maia needed)
test: $(TARGET)
	@echo ""
	@echo "Running quick offline smoke test (depth 1)..."
	@echo ""
	$(TARGET) -c w -d 1 -e 8 -t 1 test_output
	@echo ""
	@echo "Test output saved to test_output.pgn"
	@rm -f test_output.db test_output.db-shm test_output.db-wal \
		test_output.pgn test_output.tree.json

# Full test with engine
test-full: $(TARGET)
	@echo ""
	@echo "Running full test with Stockfish (depth 6, 2 engines)..."
	$(TARGET) -v -c w -p 0.01 -d 6 -e 20 -t 2 --traps test_output
	@echo ""
	@rm -f test_output.db test_output.db-shm test_output.db-wal \
		test_output.pgn test_output.tree.json test_output.traps.pgn

# Portable distribution: bundles binary + shared libs + maia model + stockfish
DIST_DIR = dist/tree_builder
MAIA_MODEL = ../assets/maia3_simplified.onnx
dist: $(TARGET)
	@echo "Creating portable distribution..."
	@rm -rf $(DIST_DIR)
	@mkdir -p $(DIST_DIR)
	@cp $(TARGET) $(DIST_DIR)/
	@# Bundle shared libraries the binary actually needs
	@ldd $(TARGET) | grep -E 'libonnxruntime|libcurl' | awk '{print $$3}' | while read lib; do \
		if [ -n "$$lib" ] && [ -f "$$lib" ]; then \
			cp -L "$$lib" $(DIST_DIR)/; \
			echo "  Bundled $$lib"; \
		fi; \
	done
	@# Bundle Maia model
	@if [ -f "$(MAIA_MODEL)" ]; then \
		cp "$(MAIA_MODEL)" $(DIST_DIR)/maia3_simplified.onnx; \
		echo "  Bundled maia3_simplified.onnx"; \
	else \
		echo "  WARNING: Maia model not found at $(MAIA_MODEL)"; \
	fi
	@# Bundle Stockfish if found
	@SF=$$(which stockfish 2>/dev/null); \
	if [ -n "$$SF" ]; then \
		cp "$$SF" $(DIST_DIR)/stockfish; \
		echo "  Bundled stockfish from $$SF"; \
	else \
		echo "  WARNING: stockfish not found, not bundled"; \
	fi
	@# Create tarball
	@cd dist && tar czf tree_builder-$$(uname -m).tar.gz tree_builder/
	@echo ""
	@echo "══════════════════════════════════════════"
	@echo "  Distribution: dist/tree_builder-$$(uname -m).tar.gz"
	@echo ""
	@echo "  Extract and run:"
	@echo "    tar xzf tree_builder-$$(uname -m).tar.gz"
	@echo "    cd tree_builder"
	@echo "    ./tree_builder -c w -v repertoire.json"
	@echo "══════════════════════════════════════════"
	@echo ""

# Help
help:
	@echo ""
	@echo "Chess Repertoire Builder - Makefile"
	@echo ""
	@echo "Targets:"
	@echo "  all        - Build the tree_builder executable (default)"
	@echo "  dist       - Build portable tarball (binary + libs + maia + stockfish)"
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
	@echo "Maia neural-network support (enabled by default):"
	@echo "  Requires ONNX Runtime shared library:"
	@echo "    Fedora:  sudo dnf install onnxruntime-devel"
	@echo "    pip:     pip install onnxruntime (set LD_LIBRARY_PATH)"
	@echo "  To disable:  make NO_MAIA=1"
	@echo ""
	@echo "After building:"
	@echo "  ./bin/tree_builder -h      (show usage)"
	@echo "  ./bin/tree_builder -v -c w repertoire.json"
	@echo ""
