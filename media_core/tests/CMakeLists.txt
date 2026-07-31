add_executable(ebadge_media_core_tests
    test_main.cpp
)

target_link_libraries(ebadge_media_core_tests PRIVATE ebadge_media_core)

target_include_directories(ebadge_media_core_tests PRIVATE
    ${PROJECT_SOURCE_DIR}/src
)

add_test(NAME ebadge_media_core_tests COMMAND ebadge_media_core_tests)
