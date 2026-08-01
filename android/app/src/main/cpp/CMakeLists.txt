cmake_minimum_required(VERSION 3.18)

project(honey_media_jni LANGUAGES C CXX)

set(BUILD_TESTING OFF CACHE BOOL "" FORCE)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

add_subdirectory(
    "${CMAKE_CURRENT_LIST_DIR}/../../../../../media_core"
    "${CMAKE_CURRENT_BINARY_DIR}/honey_media_core"
)

add_library(honey_media_jni SHARED native_media_jni.cpp)
target_compile_features(honey_media_jni PRIVATE cxx_std_17)
set_target_properties(honey_media_jni PROPERTIES CXX_EXTENSIONS NO)
target_compile_options(
    honey_media_jni
    PRIVATE -Wall -Wextra -Wpedantic -Werror -fno-exceptions -fno-rtti
)
target_link_libraries(honey_media_jni PRIVATE honey_media_core)
