add_executable(honey_media_core_tests
    test_main.cpp
    reference_fixture_test.cpp
    avi_test.cpp
    cinepak_encoder_test.cpp
    cinepak_decoder_test.cpp
    msv1_test.cpp
    malformed_corpus_test.cpp
)

target_link_libraries(honey_media_core_tests PRIVATE honey_media_core)

target_include_directories(honey_media_core_tests PRIVATE
    ${PROJECT_SOURCE_DIR}/src
)

target_compile_definitions(honey_media_core_tests PRIVATE
    HMC_FIXTURE_DIRECTORY="${CMAKE_CURRENT_SOURCE_DIR}/fixtures"
    HMC_ENABLE_TEST_HOOKS
)

if(MSVC)
    target_compile_definitions(honey_media_core_tests PRIVATE _CRT_SECURE_NO_WARNINGS)
    target_compile_options(honey_media_core_tests PRIVATE /W4 /WX /permissive-)
elseif(CMAKE_CXX_COMPILER_ID MATCHES "^(AppleClang|Clang|GNU)$")
    target_compile_options(honey_media_core_tests PRIVATE -Wall -Wextra -Wpedantic -Werror)
else()
    message(WARNING
        "honey_media_core_tests strict warnings are not configured for "
        "${CMAKE_CXX_COMPILER_ID}"
    )
endif()

add_test(NAME honey_media_core_tests COMMAND honey_media_core_tests)

add_library(honey_media_core_c99_consumer OBJECT
    test_c99_consumer.c
)

target_link_libraries(honey_media_core_c99_consumer PRIVATE honey_media_core)

set_target_properties(honey_media_core_c99_consumer PROPERTIES
    C_STANDARD 99
    C_STANDARD_REQUIRED YES
    C_EXTENSIONS NO
)

target_include_directories(honey_media_core_c99_consumer PRIVATE
    ${PROJECT_SOURCE_DIR}/include
)

if(BUILD_SHARED_LIBS)
    target_compile_definitions(honey_media_core_c99_consumer PRIVATE
        HMC_EXPECT_USE_SHARED
    )
endif()

if(MSVC)
    target_compile_options(honey_media_core_c99_consumer PRIVATE /W4 /WX)
elseif(CMAKE_C_COMPILER_ID MATCHES "^(AppleClang|Clang|GNU)$")
    target_compile_options(honey_media_core_c99_consumer PRIVATE -Wall -Wextra -Wpedantic -Werror)
else()
    message(WARNING
        "honey_media_core_c99_consumer strict warnings are not configured for "
        "${CMAKE_C_COMPILER_ID}"
    )
endif()
