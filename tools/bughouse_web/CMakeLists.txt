cmake_minimum_required(VERSION 3.20)
project(hivemind_browser LANGUAGES CXX)
if(NOT EMSCRIPTEN)
  message(FATAL_ERROR "Configure with emcmake; this target runs in a browser worker")
endif()
set(CMAKE_CXX_STANDARD 23)
set(SRC "${HIVEMIND_SOURCE}/engine/src")
add_executable(hivemind
  bridge.cc engine_web.cc thread_web.cc
  ${SRC}/common/globals.cc
  ${SRC}/environment/board.cc
  ${SRC}/environment/planes.cc
  ${SRC}/environment/zobrist.cc
  ${SRC}/search/node.cc
  ${SRC}/search/searchthread.cc
  ${SRC}/Fairy-Stockfish/src/bitboard.cpp
  ${SRC}/Fairy-Stockfish/src/misc.cpp
  ${SRC}/Fairy-Stockfish/src/movegen.cpp
  ${SRC}/Fairy-Stockfish/src/parser.cpp
  ${SRC}/Fairy-Stockfish/src/piece.cpp
  ${SRC}/Fairy-Stockfish/src/position.cpp
  ${SRC}/Fairy-Stockfish/src/stubs.cpp
  ${SRC}/Fairy-Stockfish/src/variant.cpp)
target_include_directories(hivemind PRIVATE ${SRC})
target_compile_definitions(hivemind PRIVATE NDEBUG NNUE_EMBEDDING_OFF HIVEMIND_BACKEND_WEB)
target_compile_options(hivemind PRIVATE -O3 -fexceptions)
target_link_options(hivemind PRIVATE
  -O3 -fexceptions --no-entry -sDISABLE_EXCEPTION_CATCHING=0
  -sMODULARIZE=1 -sEXPORT_ES6=1 -sEXPORT_NAME=createHivemind
  -sENVIRONMENT=web,worker,node -sALLOW_MEMORY_GROWTH=1
  -sINITIAL_MEMORY=67108864 -sMAXIMUM_MEMORY=536870912 -sSTACK_SIZE=2097152
  -sASYNCIFY=1 -sASYNCIFY_STACK_SIZE=131072
  "-sEXPORTED_FUNCTIONS=['_bh_init','_bh_position','_bh_search']"
  "-sEXPORTED_RUNTIME_METHODS=['ccall','HEAPF32']")
set_target_properties(hivemind PROPERTIES SUFFIX ".mjs")
