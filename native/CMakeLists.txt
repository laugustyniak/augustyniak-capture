# The on-device speech engine, as one small shared library.
#
# whisper.cpp is **fetched at configure time and pinned to a tag**, not vendored
# into this repository. It is a large tree that changes constantly, and copying
# it here would put a second project's history inside a public repo whose own
# history is already load-bearing. The pin is what makes the build reproducible;
# moving it is a deliberate edit with a rebuild behind it, never a drift.
#
# The first configure needs the network. Every later one is served from the
# build directory's cache, and nothing at *runtime* ever reaches out — which is
# the whole point of the feature.
cmake_minimum_required(VERSION 3.16)
project(augustyniak_whisper LANGUAGES C CXX)

include(FetchContent)

set(AUG_WHISPER_TAG "v1.7.4" CACHE STRING "whisper.cpp tag to build against")

# Everything whisper.cpp offers beyond the library itself is cost we do not pay:
# its examples pull SDL2, its tests add minutes, and neither ships in the app.
# Linked into a shared library, so every object in the dependency tree needs
# position-independent code. Without this the static whisper/ggml archives are
# built without -fPIC and the link fails with a relocation error against
# `stderr` — a failure that names the symbol rather than the cause.
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# **Portability over the last few percent of speed.** ggml defaults to
# `-march=native`, which bakes in whatever this build machine happens to
# support; the resulting bundle then dies with SIGILL on any older CPU, and it
# does so at the first transcription rather than at startup. A shipped artifact
# has to run on the machines it is copied to.
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)

# Not in the NDK sysroot, and worth nothing here anyway: the engine already
# runs on a bounded thread pool chosen by the Dart side, and a second layer of
# parallelism would fight it for the cores this deliberately leaves free.
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)

set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_TESTS    OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_SERVER   OFF CACHE BOOL "" FORCE)
set(BUILD_SHARED_LIBS      OFF CACHE BOOL "" FORCE)

# EXCLUDE_FROM_ALL keeps whisper.cpp's own `install()` rules out of ours.
# Without it the desktop bundle ships `libwhisper.a` beside the shim — a 6 MB
# static archive that is a build input, not a runtime artifact, and that
# nothing in the installed app can load.
#
# **Guarded by version because the Android NDK ships CMake 3.22**, and the
# keyword only exists from 3.28. An unknown keyword there is a hard configure
# error, not a warning. Android does not run an `install()` step at all — Gradle
# packages the `.so` straight out of the build tree — so the fallback costs
# nothing on the one platform that takes it.
set(AUG_FETCH_ARGS
  GIT_REPOSITORY https://github.com/ggerganov/whisper.cpp.git
  GIT_TAG        ${AUG_WHISPER_TAG}
  GIT_SHALLOW    TRUE
)
if(CMAKE_VERSION VERSION_GREATER_EQUAL 3.28)
  list(APPEND AUG_FETCH_ARGS EXCLUDE_FROM_ALL)
endif()

FetchContent_Declare(whisper_cpp ${AUG_FETCH_ARGS})
FetchContent_MakeAvailable(whisper_cpp)

add_library(augustyniak_whisper SHARED augustyniak_whisper.c)

target_include_directories(augustyniak_whisper PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}
  ${whisper_cpp_SOURCE_DIR}/include
  ${whisper_cpp_SOURCE_DIR}/ggml/include
)


# Linked statically so the app bundle carries exactly one extra file. A user
# copying the bundle to a machine without whisper.cpp installed is the normal
# case, not the exception.
target_link_libraries(augustyniak_whisper PRIVATE whisper)

set_target_properties(augustyniak_whisper PROPERTIES
  C_VISIBILITY_PRESET hidden
  POSITION_INDEPENDENT_CODE ON
)
