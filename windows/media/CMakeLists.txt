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
)

target_compile_features(honey_media_windows_core PUBLIC cxx_std_17)

target_include_directories(honey_media_windows_core
  PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_LIST_DIR}/include>
)

target_link_libraries(honey_media_windows_core PRIVATE honey_media_core)

if(MSVC)
  target_compile_options(honey_media_windows_core PRIVATE /W4 /WX /permissive- /EHsc)
elseif(CMAKE_CXX_COMPILER_ID MATCHES "^(AppleClang|Clang|GNU)$")
  target_compile_options(honey_media_windows_core PRIVATE -Wall -Wextra -Wpedantic -Werror)
endif()

if(BUILD_TESTING)
  add_subdirectory(tests)
endif()
