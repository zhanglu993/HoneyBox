cmake_minimum_required(VERSION 3.16)

project(honey_camera_windows LANGUAGES CXX)

include(CTest)

if(NOT TARGET honey_media_windows_core)
  add_subdirectory(
    "${CMAKE_CURRENT_LIST_DIR}/../media"
    "${CMAKE_CURRENT_BINARY_DIR}/media")
endif()
if(NOT HMW_FLUTTER_CPP_WRAPPER_DIR AND
   EXISTS "${CMAKE_CURRENT_LIST_DIR}/../flutter/ephemeral/cpp_client_wrapper/include/flutter/encodable_value.h")
  set(HMW_FLUTTER_CPP_WRAPPER_DIR
    "${CMAKE_CURRENT_LIST_DIR}/../flutter/ephemeral/cpp_client_wrapper")
endif()


add_library(honey_camera_windows_preview STATIC
  src/camera_encoding_session.cpp
  src/camera_preview_session.cpp
  src/camera_plugin_teardown.cpp
  src/camera_texture_controller.cpp
  src/camera_texture_cleanup.cpp
  src/media_foundation_camera.cpp
)

target_include_directories(honey_camera_windows_preview PUBLIC
  "${CMAKE_CURRENT_LIST_DIR}/include"
  "${CMAKE_CURRENT_LIST_DIR}/../media/include"
)

target_compile_features(honey_camera_windows_preview PUBLIC cxx_std_17)

target_link_libraries(honey_camera_windows_preview PUBLIC
  honey_media_windows_core
)

add_library(honey_camera_windows_channel STATIC
  src/windows_encoder_registration.cpp
  src/encoder_channel.cpp
)

target_include_directories(honey_camera_windows_channel PUBLIC
  "${CMAKE_CURRENT_LIST_DIR}/include"
  "${CMAKE_CURRENT_LIST_DIR}/../media/include"
)

target_compile_features(honey_camera_windows_channel PUBLIC cxx_std_17)
target_link_libraries(honey_camera_windows_channel PUBLIC
  honey_camera_windows_preview
  honey_media_windows_core
)

if(TARGET flutter AND TARGET flutter_wrapper_plugin)
  target_link_libraries(honey_camera_windows_preview PRIVATE
    flutter flutter_wrapper_plugin)
  target_link_libraries(honey_camera_windows_channel PRIVATE
    flutter flutter_wrapper_plugin)
elseif(HMW_FLUTTER_CPP_WRAPPER_DIR)
  target_include_directories(honey_camera_windows_preview PRIVATE
    "${HMW_FLUTTER_CPP_WRAPPER_DIR}/include")
  target_include_directories(honey_camera_windows_channel PUBLIC
    "${HMW_FLUTTER_CPP_WRAPPER_DIR}/include")
else()
  message(FATAL_ERROR
    "Flutter C++ wrapper headers are required for the encoder channel")
endif()


target_link_libraries(honey_camera_windows_preview PRIVATE
  mf mfplat mfreadwrite mfuuid ole32
)
if(TARGET honey_media_windows_plugin)
  target_link_libraries(honey_media_windows_plugin PRIVATE
    honey_camera_windows_channel
  )
endif()

if(MSVC)
  target_compile_options(honey_camera_windows_preview PRIVATE /W4 /WX /permissive- /EHsc)
  target_compile_options(honey_camera_windows_channel PRIVATE /W4 /WX /permissive- /EHsc)
elseif(CMAKE_CXX_COMPILER_ID MATCHES "^(AppleClang|Clang|GNU)$")
  target_compile_options(honey_camera_windows_preview PRIVATE -Wall -Wextra -Wpedantic -Werror)
  target_compile_options(honey_camera_windows_channel PRIVATE -Wall -Wextra -Wpedantic -Werror)
endif()

if(BUILD_TESTING)
  add_subdirectory(tests)
endif()
