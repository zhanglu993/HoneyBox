cmake_minimum_required(VERSION 3.16)

project(honey_media_core LANGUAGES C CXX)

if(MSVC)
    string(REGEX REPLACE "[/-]EH[a-zA-Z-]*" "" CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS}")
endif()

add_library(honey_media_core
    src/allocator.cpp
    src/avi.cpp
    src/c_api.cpp
    src/cinepak_decoder.cpp
    src/cinepak_encoder.cpp
    src/msv1.cpp
)

if(BUILD_SHARED_LIBS)
    set_target_properties(honey_media_core PROPERTIES
        RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/tests"
    )
    target_compile_definitions(honey_media_core
        PRIVATE HMC_BUILD_SHARED
        INTERFACE HMC_USE_SHARED
    )
endif()

target_compile_features(honey_media_core PUBLIC cxx_std_17)
set_target_properties(honey_media_core PROPERTIES
    CXX_EXTENSIONS NO
)

target_include_directories(honey_media_core
    PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
)

if(MSVC)
    target_compile_options(honey_media_core PRIVATE
        /W4 /WX /permissive- /EHs-c- /GR-
    )
elseif(CMAKE_CXX_COMPILER_ID MATCHES "^(AppleClang|Clang|GNU)$")
    target_compile_options(honey_media_core PRIVATE -Wall -Wextra -Wpedantic -Werror -fno-exceptions -fno-rtti)
else()
    message(WARNING
        "honey_media_core strict warnings are not configured for "
        "${CMAKE_CXX_COMPILER_ID}"
    )
endif()

# Cinepak VQ uses ordered IEEE-754 operations as part of its byte-stream
# contract. Keep these options after general/global flags so host fast-math or
# contraction settings cannot change codebook labels across toolchains.
if(MSVC)
    target_compile_options(honey_media_core PRIVATE /fp:strict)
elseif(CMAKE_CXX_COMPILER_ID MATCHES "^(AppleClang|Clang|GNU)$")
    target_compile_options(honey_media_core PRIVATE -fno-fast-math -ffp-contract=off)
endif()

include(CTest)
if(BUILD_TESTING)
    target_compile_definitions(honey_media_core PRIVATE HMC_ENABLE_TEST_HOOKS)
    add_subdirectory(tests)
endif()
