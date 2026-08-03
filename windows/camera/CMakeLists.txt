cmake_minimum_required(VERSION 3.16)

project(honey_camera_windows LANGUAGES CXX)

include(CTest)

if(NOT TARGET honey_media_windows_core)
  add_subdirectory(
    "${CMAKE_CURRENT_LIST_DIR}/../media"
    "${CMAKE_CURRENT_BINARY_DIR}/media")
endif()

add_library(honey_camera_windows_preview STATIC
  src/camera_preview_session.cpp
)

target_include_directories(honey_camera_windows_preview PUBLIC
  "${CMAKE_CURRENT_LIST_DIR}/include"
  "${CMAKE_CURRENT_LIST_DIR}/../media/include"
)

target_compile_features(honey_camera_windows_preview PUBLIC cxx_std_17)

if(MSVC)
  target_compile_options(honey_camera_windows_preview PRIVATE /W4 /WX /permissive-)
elseif(CMAKE_CXX_COMPILER_ID MATCHES "^(AppleClang|Clang|GNU)$")
  target_compile_options(honey_camera_windows_preview PRIVATE -Wall -Wextra -Wpedantic -Werror)
endif()

if(BUILD_TESTING)
  add_subdirectory(tests)
endif()
