add_executable(honey_media_windows_tests
  test_main.cpp
  channel_contract_test.cpp
  media_foundation_source_test.cpp
  forward_sampler_test.cpp
  h264_annex_b_test.cpp
  media_foundation_h264_encoder_test.cpp
  playback_clock_test.cpp
  rgba_transform_test.cpp
  rgba_nv12_test.cpp
  status_contract_test.cpp
  video_player_state_test.cpp
  wic_media_test.cpp
)

target_include_directories(honey_media_windows_tests PRIVATE
  "${CMAKE_CURRENT_LIST_DIR}/../include"
  "${CMAKE_CURRENT_LIST_DIR}/../src"
)

target_compile_features(honey_media_windows_tests PRIVATE cxx_std_17)

target_link_libraries(honey_media_windows_tests PRIVATE
  honey_media_windows_core
  ole32
  windowscodecs
)

target_compile_definitions(honey_media_windows_tests PRIVATE
  HMW_PROJECT_SOURCE_DIR="${CMAKE_CURRENT_LIST_DIR}/../../.."
  HMW_TEST_SOURCE_DIR="${CMAKE_CURRENT_LIST_DIR}"
)

if(MSVC)
  target_compile_options(honey_media_windows_tests PRIVATE /W4 /WX /permissive-)
elseif(CMAKE_CXX_COMPILER_ID MATCHES "^(AppleClang|Clang|GNU)$")
  target_compile_options(honey_media_windows_tests PRIVATE -Wall -Wextra -Wpedantic -Werror)
endif()

add_test(NAME channel_contract COMMAND honey_media_windows_tests channel_contract)
add_test(NAME rgba_transform COMMAND honey_media_windows_tests transform_)
add_test(NAME rgba_nv12 COMMAND honey_media_windows_tests rgba_nv12)
add_test(NAME status_contract COMMAND honey_media_windows_tests status_contract)
add_test(NAME h264_annex_b COMMAND honey_media_windows_tests h264_annex_b)
add_test(NAME media_foundation_h264_encoder
  COMMAND honey_media_windows_tests media_foundation_h264_encoder)
add_test(NAME wic_media COMMAND honey_media_windows_tests wic_media)
add_test(NAME media_foundation_source COMMAND honey_media_windows_tests media_foundation_source)
add_test(NAME playback_clock COMMAND honey_media_windows_tests clock_)
add_test(NAME video_player_state COMMAND honey_media_windows_tests player_)
add_test(NAME forward_sampler COMMAND honey_media_windows_tests forward_sampler_)

add_executable(hmw_windows_media_smoke
  test_main.cpp
  windows_media_smoke.cpp
)

target_include_directories(hmw_windows_media_smoke PRIVATE
  "${CMAKE_CURRENT_LIST_DIR}/../include"
  "${CMAKE_CURRENT_LIST_DIR}/../src"
  "${CMAKE_CURRENT_LIST_DIR}"
)

target_compile_features(hmw_windows_media_smoke PRIVATE cxx_std_17)
target_link_libraries(hmw_windows_media_smoke PRIVATE
  honey_media_windows_core
  honey_media_core
)
target_compile_definitions(hmw_windows_media_smoke PRIVATE
  HMW_PROJECT_SOURCE_DIR="${CMAKE_CURRENT_LIST_DIR}/../../.."
  HMW_TEST_SOURCE_DIR="${CMAKE_CURRENT_LIST_DIR}"
)
if(MSVC)
  target_compile_options(hmw_windows_media_smoke PRIVATE /W4 /WX /permissive-)
endif()
add_test(NAME windows_media_smoke COMMAND hmw_windows_media_smoke)

add_executable(hmw_windows_media_benchmark
  benchmark_support.cpp
  windows_media_benchmark.cpp
)

target_include_directories(hmw_windows_media_benchmark PRIVATE
  "${CMAKE_CURRENT_LIST_DIR}/../include"
  "${CMAKE_CURRENT_LIST_DIR}/../src"
  "${CMAKE_CURRENT_LIST_DIR}"
)

target_compile_features(hmw_windows_media_benchmark PRIVATE cxx_std_17)
target_link_libraries(hmw_windows_media_benchmark PRIVATE
  honey_media_windows_core
  honey_media_core
  advapi32
)
target_compile_definitions(hmw_windows_media_benchmark PRIVATE
  HMW_PROJECT_SOURCE_DIR="${CMAKE_CURRENT_LIST_DIR}/../../.."
)
if(MSVC)
  target_compile_options(hmw_windows_media_benchmark
    PRIVATE /W4 /WX /permissive-)
endif()
