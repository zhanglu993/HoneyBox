add_executable(honey_media_core_tests
    test_main.cpp
    reference_fixture_test.cpp
    avi_test.cpp
)

target_link_libraries(honey_media_core_tests PRIVATE honey_media_core)

target_include_directories(honey_media_core_tests PRIVATE
    ${PROJECT_SOURCE_DIR}/src
)

target_compile_definitions(honey_media_core_tests PRIVATE
    HMC_FIXTURE_DIRECTORY="${CMAKE_CURRENT_SOURCE_DIR}/fixtures"
    HMC_ENABLE_TEST_HOOKS
)

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
else()
    target_compile_options(honey_media_core_c99_consumer PRIVATE -Wall -Wextra -Wpedantic -Werror)
endif()
