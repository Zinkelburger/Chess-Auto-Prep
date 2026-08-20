# Fetch the host Stockfish into assets/executables/ during CMake configure so
# `flutter run` / `flutter build` can bundle it. fetch_assets.py is a no-op
# when the .gz already matches tools/assets.lock.json (CI fetches first).
#
# macOS is handled in the Flutter Assemble script (fetch only if the .gz is
# missing) so the Intel CI job on Apple Silicon runners cannot overwrite a
# pre-fetched x86_64 engine.
function(chess_auto_prep_fetch_stockfish target_name)
  # Release CI fetches with --only before `flutter build`. Integration tests
  # must not download ~110 MB during CMake configure (5-minute timeout).
  if(DEFINED ENV{GITHUB_ACTIONS})
    message(STATUS "GitHub Actions: leaving Stockfish fetch to the workflow")
    return()
  endif()
  set(_root "${CMAKE_CURRENT_SOURCE_DIR}/..")
  find_program(_py NAMES python3 python)
  if(NOT _py)
    message(STATUS
      "Python not found; skip Stockfish fetch. Run tools/fetch_assets.py "
      "or the app will download the engine on first use.")
    return()
  endif()
  execute_process(
    COMMAND "${_py}" "${_root}/tools/fetch_assets.py" --only "${target_name}"
    WORKING_DIRECTORY "${_root}"
    RESULT_VARIABLE _rc
  )
  if(NOT _rc EQUAL 0)
    message(WARNING
      "Stockfish fetch failed (exit ${_rc}). "
      "The app will try to download on first engine use.")
  endif()
endfunction()
