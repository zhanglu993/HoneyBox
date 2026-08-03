# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(HoneyBox LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "HoneyBox")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Silence coroutine deprecation warnings in permission_handler_windows with
# newer Visual Studio toolchains (VS 2025+ / MSVC 14.50+).
add_definitions(-D_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Windows-native media adapter. Its build remains independent of Flutter and
# consumes the platform-neutral honey_media_core target.
add_subdirectory("media")
add_subdirectory("camera")

# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)

# permission_handler_windows 0.2.1 adds legacy /await even though it already
# compiles as C++20, where standard coroutines are enabled by default. MSVC
# 14.50+ reports D9047 for that obsolete option.
if(TARGET permission_handler_windows_plugin)
  get_target_property(PHW_COMPILE_OPTIONS
    permission_handler_windows_plugin COMPILE_OPTIONS)
  if(PHW_COMPILE_OPTIONS)
    list(REMOVE_ITEM PHW_COMPILE_OPTIONS "/await")
    set_property(TARGET permission_handler_windows_plugin PROPERTY
      COMPILE_OPTIONS "${PHW_COMPILE_OPTIONS}")
  endif()
endif()

# flutter_blue_plus_winrt 0.0.20 lets synchronous WinRT exceptions escape its
# method-channel callback. Generate a project-local patched translation unit so
# a Bluetooth watcher failure is returned to Dart instead of terminating the
# Windows process. The package cache remains untouched.
if(TARGET flutter_blue_plus_winrt_plugin)
  set(FBP_WINRT_SOURCE_DIR
    "${FLUTTER_MANAGED_DIR}/ephemeral/.plugin_symlinks/flutter_blue_plus_winrt/windows")
  set(FBP_WINRT_PATCHED_SOURCE
    "${CMAKE_CURRENT_BINARY_DIR}/generated/flutter_blue_plus_winrt_plugin.cpp")
  execute_process(
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
      -File "${CMAKE_CURRENT_SOURCE_DIR}/../tool/patch_flutter_blue_plus_winrt.ps1"
      -SourcePath "${FBP_WINRT_SOURCE_DIR}/flutter_blue_plus_winrt_plugin.cpp"
      -OutputPath "${FBP_WINRT_PATCHED_SOURCE}"
    RESULT_VARIABLE FBP_WINRT_PATCH_RESULT
    ERROR_VARIABLE FBP_WINRT_PATCH_ERROR)
  if(NOT FBP_WINRT_PATCH_RESULT EQUAL 0)
    message(FATAL_ERROR
      "Failed to patch flutter_blue_plus_winrt: ${FBP_WINRT_PATCH_ERROR}")
  endif()

  get_target_property(FBP_WINRT_PLUGIN_SOURCES
    flutter_blue_plus_winrt_plugin SOURCES)
  list(FILTER FBP_WINRT_PLUGIN_SOURCES EXCLUDE REGEX
    "flutter_blue_plus_winrt_plugin\\.cpp$")
  set_property(TARGET flutter_blue_plus_winrt_plugin PROPERTY SOURCES
    "${FBP_WINRT_PLUGIN_SOURCES}")
  target_sources(flutter_blue_plus_winrt_plugin PRIVATE
    "${FBP_WINRT_PATCHED_SOURCE}")
  target_include_directories(flutter_blue_plus_winrt_plugin PRIVATE
    "${FBP_WINRT_SOURCE_DIR}")
endif()

# Suppress C4864 ("expected 'template' keyword before dependent template name")
# in flutter_blue_plus_winrt. It fires in the plugin's C++/WinRT projected types
# under newer MSVC (VS 2026 / MSVC v143+); combined with Flutter's /WX
# (warnings-as-errors) it would abort the Windows build. Project-level override
# so we don't have to patch the pub cache. See:
# https://github.com/chan150/flutter_blue_plus_winrt/issues/2
if(TARGET flutter_blue_plus_winrt_plugin)
  target_compile_options(flutter_blue_plus_winrt_plugin PRIVATE /wd"4864")
endif()


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)
