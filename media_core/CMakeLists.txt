cmake_minimum_required(VERSION 3.16)

project(ebadge_media_core LANGUAGES CXX)

if(MSVC)
    string(REPLACE "/EHsc" "" CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS}")
endif()

add_library(ebadge_media_core STATIC
    src/c_api.cpp
)

target_compile_features(ebadge_media_core PUBLIC cxx_std_17)
set_target_properties(ebadge_media_core PROPERTIES
    CXX_EXTENSIONS NO
)

target_include_directories(ebadge_media_core
    PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
)

if(MSVC)
    target_compile_options(ebadge_media_core PRIVATE /W4 /WX /GR-)
else()
    target_compile_options(ebadge_media_core PRIVATE -Wall -Wextra -Wpedantic -Werror -fno-exceptions -fno-rtti)
endif()

include(CTest)
if(BUILD_TESTING)
    add_subdirectory(tests)
endif()
