# Fetch the host engines (Stockfish into assets/executables/, the bughouse
# engine into assets/bughouse/) during CMake configure so `flutter run` /
# `flutter build` can bundle them. fetch_assets.py is a no-op when the .gz
# files already match tools/assets.lock.json (CI fetches first).
#
# macOS is handled in the Flutter Assemble script. Both paths leave the
# explicit target fetch to the workflow when running in GitHub Actions.
function(chess_auto_prep_fetch_assets)
  # Release CI fetches with --only before `flutter build`. Integration tests
  # must not download ~120 MB during CMake configure (5-minute timeout).
  if(DEFINED ENV{GITHUB_ACTIONS})
    message(STATUS "GitHub Actions: leaving the engine fetch to the workflow")
    return()
  endif()
  set(_root "${CMAKE_CURRENT_SOURCE_DIR}/..")
  find_program(_py NAMES python3 python)
  if(NOT _py)
    message(STATUS
      "Python not found; skip the engine fetch. Run tools/fetch_assets.py "
      "or the app will download Stockfish on first use (Bughouse Lab stays hidden).")
    return()
  endif()
  execute_process(
    COMMAND "${_py}" "${_root}/tools/fetch_assets.py"
    WORKING_DIRECTORY "${_root}"
    RESULT_VARIABLE _rc
  )
  if(NOT _rc EQUAL 0)
    message(WARNING
      "Engine fetch failed (exit ${_rc}). "
      "The app will try to download Stockfish on first engine use; "
      "Bughouse Lab stays hidden until tools/fetch_assets.py succeeds.")
  endif()
endfunction()
