cmake_minimum_required(VERSION 3.10)
set(PROJECT_NAME "cdbdirect_flutter_libs")
project(${PROJECT_NAME} LANGUAGES CXX)

set(CDBDIRECT_LIB "${CMAKE_CURRENT_SOURCE_DIR}/../native/linux-x64/libcdbdirect.so")

if(EXISTS "${CDBDIRECT_LIB}")
  set(cdbdirect_flutter_libs_bundled_libraries
    "${CDBDIRECT_LIB}"
    PARENT_SCOPE
  )
else()
  message(STATUS "cdbdirect_flutter_libs: no prebuilt lib at ${CDBDIRECT_LIB} — app will run without bundled reader")
  set(cdbdirect_flutter_libs_bundled_libraries
    ""
    PARENT_SCOPE
  )
endif()
