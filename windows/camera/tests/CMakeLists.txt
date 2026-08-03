add_executable(honey_camera_windows_tests
  "${CMAKE_CURRENT_LIST_DIR}/../../media/tests/test_main.cpp"
  camera_status_test.cpp
  camera_preview_session_test.cpp
  camera_preview_session_reentrancy_test.cpp
  camera_preview_queue_test.cpp
  media_foundation_camera_test.cpp
)

target_include_directories(honey_camera_windows_tests PRIVATE
  "${CMAKE_CURRENT_LIST_DIR}/../../../media_core/include"
  "${CMAKE_CURRENT_LIST_DIR}/../../media/include"
  "${CMAKE_CURRENT_LIST_DIR}/../../media/tests"
  "${CMAKE_CURRENT_LIST_DIR}/../src"
)

target_compile_features(honey_camera_windows_tests PRIVATE cxx_std_17)

target_link_libraries(honey_camera_windows_tests PRIVATE
  honey_media_windows_core
  honey_camera_windows_preview
)

target_compile_definitions(honey_camera_windows_tests PRIVATE
  HMW_PROJECT_SOURCE_DIR="${CMAKE_CURRENT_LIST_DIR}/../../.."
  HMW_TEST_SOURCE_DIR="${CMAKE_CURRENT_LIST_DIR}"
)

if(MSVC)
  target_compile_options(honey_camera_windows_tests PRIVATE /W4 /WX /permissive-)
elseif(CMAKE_CXX_COMPILER_ID MATCHES "^(AppleClang|Clang|GNU)$")
  target_compile_options(honey_camera_windows_tests PRIVATE -Wall -Wextra -Wpedantic -Werror)
endif()

add_test(NAME camera_status
  COMMAND honey_camera_windows_tests camera_status)

add_test(NAME camera_preview_session
  COMMAND honey_camera_windows_tests camera_preview_)

add_test(NAME camera_mode_helpers
  COMMAND honey_camera_windows_tests camera_mode_)

add_test(NAME camera_bgra_helpers
  COMMAND honey_camera_windows_tests camera_bgra_)

add_test(NAME camera_rgba_helpers
  COMMAND honey_camera_windows_tests camera_rgba_)
