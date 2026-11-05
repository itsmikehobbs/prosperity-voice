cmake_minimum_required(VERSION 3.22)
project(pvwhisper LANGUAGES C CXX)

# whisper.cpp, pinned to a release, downloaded at build time.
include(FetchContent)
set(WHISPER_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
FetchContent_Declare(whisper
    URL https://github.com/ggml-org/whisper.cpp/archive/refs/tags/v1.9.5.tar.gz
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
FetchContent_MakeAvailable(whisper)

add_library(pvwhisper SHARED whisper_jni.cpp)
target_link_libraries(pvwhisper whisper android log)
target_compile_options(pvwhisper PRIVATE -O3)
