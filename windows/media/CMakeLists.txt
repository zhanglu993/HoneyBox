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
  src/channel_contract.cpp
  src/cinepak_pipeline.cpp
  src/gif_source.cpp
  src/media_foundation_runtime.cpp
  src/media_foundation_source.cpp
  src/media_foundation_source_internal.cpp
  src/media_source_factory.cpp
  src/media_converter.cpp
  src/png_codec.cpp
  src/rgba_transform.cpp
  src/wic_helpers.cpp
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

if(BUILD_TESTING)
  add_subdirectory(tests)
  target_sources(honey_media_windows_tests PRIVATE
    tests/media_converter_test.cpp
  )
  target_link_libraries(honey_media_windows_tests PRIVATE honey_media_core)
  add_test(NAME media_converter_convert_mov
    COMMAND honey_media_windows_tests convert_mov_produces_readable_cvid_avi)
  add_test(NAME media_converter_convert_gif
    COMMAND honey_media_windows_tests convert_gif_uses_requested_background_and_timeline)
  add_test(NAME media_converter_progress
    COMMAND honey_media_windows_tests convert_progress_is_monotonic_and_finishes_at_total)
  add_test(NAME media_converter_cancel
    COMMAND honey_media_windows_tests convert_cancel_returns_no_partial_avi)
  add_test(NAME media_converter_png_cancel
    COMMAND honey_media_windows_tests png_operations_recheck_cancel_after_encoder_returns)
  add_test(NAME media_converter_slideshow
    COMMAND honey_media_windows_tests slideshow_forces_key_frame_for_each_source_slide)
  add_test(NAME media_converter_scroll
    COMMAND honey_media_windows_tests scroll_output_loops_without_visible_seam)
  add_test(NAME media_converter_cached_decode
    COMMAND honey_media_windows_tests cached_cvid_decodes_stateful_frames_in_order)
  add_test(NAME media_converter_thumbnail_preview
    COMMAND honey_media_windows_tests thumbnail_and_preview_obey_max_edge_and_count)
  add_test(NAME media_converter_dispatch
    COMMAND honey_media_windows_tests job_dispatch_covers_every_converter_channel_operation)
endif()
