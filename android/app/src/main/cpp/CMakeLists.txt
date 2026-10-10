cmake_minimum_required(VERSION 3.22.1)

# Gradle passes CMAKE_BUILD_TYPE=Debug for `flutter build apk --debug`, which compiles ggml with
# no -O at all (-g only): inference ran ~50x too slow and a reply never arrived. Model code is
# always optimized; only the Dart/Kotlin side is a debug build.
set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)

project(llama_jni C CXX)

set(LLAMA_DIR ${CMAKE_CURRENT_SOURCE_DIR}/llama.cpp)
if(NOT EXISTS ${LLAMA_DIR}/CMakeLists.txt)
    message(FATAL_ERROR "llama.cpp sources missing. From the repo root run:\n"
        "  git clone --depth 1 --branch b11541 https://github.com/ggml-org/llama.cpp android/app/src/main/cpp/llama.cpp")
endif()

# One self-contained libllama_jni.so: static llama/ggml, no OpenMP runtime, no network-fetched extras.
# ponytail: baseline armv8-a kernels (no dotprod/i8mm) so every arm64 phone runs it;
# for speed, set GGML_CPU_ARM_ARCH=armv8.2-a+dotprod or GGML_BACKEND_DL + GGML_CPU_ALL_VARIANTS.
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_COMMON OFF CACHE BOOL "" FORCE)
add_subdirectory(${LLAMA_DIR} llama EXCLUDE_FROM_ALL)

add_library(llama_jni SHARED llama_jni.cpp)
target_link_libraries(llama_jni PRIVATE llama log)
