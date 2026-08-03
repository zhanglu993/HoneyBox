cmake_minimum_required(VERSION 3.16)

project(honey_camera_windows LANGUAGES CXX)

include(CTest)

if(NOT TARGET honey_media_windows_core)
  add_subdirectory(
    "${CMAKE_CURRENT_LIST_DIR}/../media"
    "${CMAKE_CURRENT_BINARY_DIR}/media")
endif()

if(BUILD_TESTING)
  add_subdirectory(tests)
endif()
