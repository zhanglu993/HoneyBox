add_executable(honey_media_windows_tests
  test_main.cpp
  channel_contract_test.cpp
  status_contract_test.cpp
)

target_include_directories(honey_media_windows_tests PRIVATE
  "${CMAKE_CURRENT_LIST_DIR}/../include"
)

target_compile_features(honey_media_windows_tests PRIVATE cxx_std_17)

target_link_libraries(honey_media_windows_tests PRIVATE
  honey_media_windows_core
)

if(MSVC)
  target_compile_options(honey_media_windows_tests PRIVATE /W4 /WX /permissive-)
elseif(CMAKE_CXX_COMPILER_ID MATCHES "^(AppleClang|Clang|GNU)$")
  target_compile_options(honey_media_windows_tests PRIVATE -Wall -Wextra -Wpedantic -Werror)
endif()

add_test(NAME channel_contract COMMAND honey_media_windows_tests)
add_test(NAME status_contract COMMAND honey_media_windows_tests)
