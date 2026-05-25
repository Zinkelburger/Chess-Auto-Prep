cmake_minimum_required(VERSION 3.14)
set(PROJECT_NAME "cdbdirect_flutter_libs")
project(${PROJECT_NAME} LANGUAGES CXX)

set(CDBDIRECT_DLL "${CMAKE_CURRENT_SOURCE_DIR}/../native/windows-x64/cdbdirect.dll")

if(EXISTS "${CDBDIRECT_DLL}")
  set(cdbdirect_flutter_libs_bundled_libraries
    "${CDBDIRECT_DLL}"
    PARENT_SCOPE
  )
else()
  message(STATUS "cdbdirect_flutter_libs: no prebuilt DLL at ${CDBDIRECT_DLL}")
  set(cdbdirect_flutter_libs_bundled_libraries
    ""
    PARENT_SCOPE
  )
endif()
