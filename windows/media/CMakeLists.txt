cmake_minimum_required(VERSION 3.16)

project(honey_media_windows LANGUAGES CXX)

# When this adapter is embedded by the Flutter Windows project, keep its tests
# opt-in. The standalone test script explicitly sets BUILD_TESTING=ON.
if(NOT CMAKE_CURRENT_SOURCE_DIR STREQUAL CMAKE_SOURCE_DIR)
  option(BUILD_TESTING "Build tests" OFF)
endif()

include(CTest)

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

if(BUILD_TESTING)
  add_subdirectory(tests)
  target_sources(honey_media_windows_tests PRIVATE
    tests/benchmark_support.cpp
    tests/benchmark_support_test.cpp
    tests/bluetooth_address_test.cpp
    tests/conversion_controller_test.cpp
    tests/media_converter_test.cpp
    tests/windows_media_plugin_internal_test.cpp
  )
  target_link_libraries(honey_media_windows_tests PRIVATE honey_media_core advapi32 bcrypt)
  add_test(NAME media_converter_convert_mov
    COMMAND honey_media_windows_tests convert_mov_produces_readable_cvid_avi)
  add_test(NAME media_converter_frame_plan
    COMMAND honey_media_windows_tests frame_plan_preserves_a_short_gif_tail_without_changing_mov)
  add_test(NAME media_converter_convert_gif
    COMMAND honey_media_windows_tests convert_gif_uses_requested_background_and_timeline)
  add_test(NAME media_converter_convert_short_gif
    COMMAND honey_media_windows_tests convert_gif_keeps_a_partial_tail_on_the_sampling_timeline)
  add_test(NAME media_converter_progress
    COMMAND honey_media_windows_tests convert_progress_is_monotonic_and_finishes_at_total)
  add_test(NAME media_converter_cancel
    COMMAND honey_media_windows_tests convert_cancel_returns_no_partial_avi)
  add_test(NAME media_converter_png_cancel
    COMMAND honey_media_windows_tests png_)
  add_test(NAME media_converter_slideshow
    COMMAND honey_media_windows_tests slideshow_forces_key_frame_for_each_source_slide)
  add_test(NAME media_converter_scroll
    COMMAND honey_media_windows_tests scroll_output_loops_without_visible_seam)
  add_test(NAME media_converter_cached_decode
    COMMAND honey_media_windows_tests cached_cvid_decodes_stateful_frames_in_order)
  add_test(NAME media_converter_thumbnail_preview
    COMMAND honey_media_windows_tests thumbnail_and_preview_obey_max_edge_and_count)
  add_test(NAME benchmark_support
    COMMAND honey_media_windows_tests benchmark_)
  add_test(NAME bluetooth_address
    COMMAND honey_media_windows_tests bluetooth_address_)
  add_test(NAME media_converter_identity
    COMMAND honey_media_windows_tests identity_conversion_frame_requires_exact_safe_context)
  add_test(NAME media_converter_dispatch
    COMMAND honey_media_windows_tests job_dispatch_covers_every_converter_channel_operation)
  add_test(NAME conversion_controller_state
    COMMAND honey_media_windows_tests controller_)
  add_test(NAME conversion_controller_dispatch_failure
    COMMAND honey_media_windows_tests dispatch_failure_)
  add_test(NAME conversion_controller_win32_dispatcher
    COMMAND honey_media_windows_tests win32_dispatcher_)
  add_test(NAME windows_media_plugin_dispatch_window
    COMMAND honey_media_windows_tests win32_dispatch_window_)

  set(HMW_FLUTTER_CPP_WRAPPER_DIR "" CACHE PATH
    "Flutter cpp_client_wrapper directory for channel adapter tests")
  if(NOT HMW_FLUTTER_CPP_WRAPPER_DIR AND
     EXISTS "${CMAKE_CURRENT_LIST_DIR}/../flutter/ephemeral/cpp_client_wrapper/include/flutter/encodable_value.h")
    set(HMW_FLUTTER_CPP_WRAPPER_DIR
      "${CMAKE_CURRENT_LIST_DIR}/../flutter/ephemeral/cpp_client_wrapper")
  endif()
  if(HMW_FLUTTER_CPP_WRAPPER_DIR)
    add_executable(honey_media_windows_flutter_value_reader_tests
      tests/test_main.cpp
      tests/flutter_value_reader_test.cpp
      tests/converter_channel_test.cpp
      tests/converter_channel_contract_test.cpp
      tests/flutter_texture_registry_test.cpp
      tests/player_channel_contract_test.cpp
      src/flutter_value_reader.cpp
      src/flutter_texture_registry.cpp
      src/converter_channel.cpp
      src/player_channel.cpp
    )
    target_compile_features(honey_media_windows_flutter_value_reader_tests
      PRIVATE cxx_std_17)
    target_include_directories(honey_media_windows_flutter_value_reader_tests
      PRIVATE
        "${CMAKE_CURRENT_LIST_DIR}/include"
        "${CMAKE_CURRENT_LIST_DIR}/src"
        "${CMAKE_CURRENT_LIST_DIR}/tests"
        "${HMW_FLUTTER_CPP_WRAPPER_DIR}/include"
        "${HMW_FLUTTER_CPP_WRAPPER_DIR}/.."
    )
    target_link_libraries(honey_media_windows_flutter_value_reader_tests
      PRIVATE honey_media_windows_core honey_media_core)
    target_compile_definitions(honey_media_windows_flutter_value_reader_tests
      PRIVATE
        HMW_PROJECT_SOURCE_DIR="${CMAKE_CURRENT_LIST_DIR}/../.."
        HMW_TEST_SOURCE_DIR="${CMAKE_CURRENT_LIST_DIR}/tests"
    )
    if(MSVC)
      target_compile_options(honey_media_windows_flutter_value_reader_tests
        PRIVATE /W4 /WX /permissive-)
    endif()
    add_test(NAME flutter_value_reader
      COMMAND honey_media_windows_flutter_value_reader_tests)
    add_test(NAME converter_channel_contract
      COMMAND honey_media_windows_flutter_value_reader_tests channel_)
    add_test(NAME player_channel_contract
      COMMAND honey_media_windows_flutter_value_reader_tests player_channel_)
    add_test(NAME flutter_texture_registry
      COMMAND honey_media_windows_flutter_value_reader_tests flutter_texture_)
  endif()
endif()
