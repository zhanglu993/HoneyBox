add_executable(honey_media_core_tests
    test_main.cpp
)

target_link_libraries(honey_media_core_tests PRIVATE honey_media_core)

target_include_directories(honey_media_core_tests PRIVATE
    ${PROJECT_SOURCE_DIR}/src
)

add_test(NAME honey_media_core_tests COMMAND honey_media_core_tests)

add_library(honey_media_core_c99_consumer OBJECT
    test_c99_consumer.c
)

set_target_properties(honey_media_core_c99_consumer PROPERTIES
    C_STANDARD 99
    C_STANDARD_REQUIRED YES
    C_EXTENSIONS NO
)

target_include_directories(honey_media_core_c99_consumer PRIVATE
    ${PROJECT_SOURCE_DIR}/include
)

if(MSVC)
    target_compile_options(honey_media_core_c99_consumer PRIVATE /W4 /WX)
else()
    target_compile_options(honey_media_core_c99_consumer PRIVATE -Wall -Wextra -Wpedantic -Werror)
endif()
