cmake_minimum_required(VERSION 3.16)

project(honey_media_windows LANGUAGES CXX)

add_subdirectory(
  "${CMAKE_CURRENT_LIST_DIR}/../../media_core"
  "${CMAKE_CURRENT_BINARY_DIR}/media_core")

add_library(honey_media_windows_core
  src/bluetooth_address.cpp
  src/channel_contract.cpp
  src/cinepak_pipeline.cpp
  src/conversion_controller.cpp
  src/encoder_backend_factory.cpp
  src/h264_annex_b.cpp
  src/media_foundation_h264_encoder.cpp
  src/gif_source.cpp
  src/media_foundation_runtime.cpp
  src/media_foundation_source.cpp
  src/media_foundation_source_internal.cpp
  src/media_source_factory.cpp
  src/media_converter.cpp
  src/playback_clock.cpp
  src/platform_dispatcher.cpp
  src/png_codec.cpp
  src/rgba_transform.cpp
  src/rgba_nv12.cpp
  src/status.cpp
  src/video_texture_player.cpp
  src/wic_helpers.cpp
  src/windows_media_plugin_internal.cpp
)

target_compile_features(honey_media_windows_core PUBLIC cxx_std_17)

target_include_directories(honey_media_windows_core
  PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_LIST_DIR}/include>
)

target_link_libraries(honey_media_windows_core PRIVATE
  honey_media_core
  mfplat
  mfreadwrite
  mfuuid
  ole32
  windowscodecs
)

if(MSVC)
  target_compile_options(honey_media_windows_core PRIVATE /W4 /WX /permissive- /EHsc)
elseif(CMAKE_CXX_COMPILER_ID MATCHES "^(AppleClang|Clang|GNU)$")
  target_compile_options(honey_media_windows_core PRIVATE -Wall -Wextra -Wpedantic -Werror)
endif()

if(TARGET flutter AND TARGET flutter_wrapper_plugin)
  add_library(honey_media_windows_plugin STATIC
    src/bluetooth_link.cpp
    src/bluetooth_link_channel.cpp
    src/converter_channel.cpp
    src/flutter_texture_registry.cpp
    src/flutter_value_reader.cpp
    src/player_channel.cpp
    src/windows_media_plugin.cpp
  )
  # C++/WinRT needs coroutine support, which MSVC gates behind /await in C++17.
  target_compile_features(honey_media_windows_plugin PUBLIC cxx_std_17)
  if(MSVC)
    target_compile_options(honey_media_windows_plugin PRIVATE /await)
  endif()
  target_link_libraries(honey_media_windows_plugin PRIVATE windowsapp)
  target_include_directories(honey_media_windows_plugin
    PUBLIC
      $<BUILD_INTERFACE:${CMAKE_CURRENT_LIST_DIR}/include>
    PRIVATE
      "${CMAKE_CURRENT_LIST_DIR}/src"
  )
  target_link_libraries(honey_media_windows_plugin
    PUBLIC honey_media_windows_core
    PRIVATE flutter flutter_wrapper_plugin
  )
  target_compile_definitions(honey_media_windows_plugin PRIVATE NOMINMAX)
  if(MSVC)
    target_compile_options(honey_media_windows_plugin
      PRIVATE /W4 /WX /permissive- /EHsc)
  elseif(CMAKE_CXX_COMPILER_ID MATCHES "^(AppleClang|Clang|GNU)$")
    target_compile_options(honey_media_windows_plugin
      PRIVATE -Wall -Wextra -Wpedantic -Werror)
  endif()
endif()
