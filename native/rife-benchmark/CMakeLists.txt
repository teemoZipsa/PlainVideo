cmake_minimum_required(VERSION 3.24)

project(PlainVideoRifeBenchmark LANGUAGES C CXX)

if(NOT WIN32)
  message(FATAL_ERROR "The PlainVideo RIFE spike currently supports Windows only.")
endif()

if(MSVC)
  # Keep the DLL self-contained and apply the same CRT choice to ncnn/glslang.
  # This must be set before adding either third-party subdirectory.
  set(CMAKE_MSVC_RUNTIME_LIBRARY
      "MultiThreaded$<$<CONFIG:Debug>:Debug>" CACHE STRING "" FORCE)
endif()

set(PLAINVIDEO_RIFE_SOURCE_DIR "" CACHE PATH
    "Pinned VapourSynth-RIFE-ncnn-Vulkan source directory")
option(PLAINVIDEO_RIFE_GPU_TIMESTAMP_DIAGNOSTICS
       "Build development-only Vulkan stage timestamp diagnostics" OFF)
option(PLAINVIDEO_RIFE_FUSED_CONCAT_DIAGNOSTICS
       "Build development-only fused RIFE Concat diagnostics" OFF)

if(NOT EXISTS "${PLAINVIDEO_RIFE_SOURCE_DIR}/RIFE/warp.cpp"
   OR NOT EXISTS "${PLAINVIDEO_RIFE_SOURCE_DIR}/RIFE/rife_ops.h"
   OR NOT EXISTS "${PLAINVIDEO_RIFE_SOURCE_DIR}/RIFE/rife_preproc.comp.hex.h"
   OR NOT EXISTS "${PLAINVIDEO_RIFE_SOURCE_DIR}/RIFE/rife_postproc.comp.hex.h"
   OR NOT EXISTS "${PLAINVIDEO_RIFE_SOURCE_DIR}/RIFE/rife_v4_timestep.comp.hex.h")
  message(FATAL_ERROR
    "PLAINVIDEO_RIFE_SOURCE_DIR must point to the pinned "
    "VapourSynth-RIFE-ncnn-Vulkan checkout.")
endif()

set(NCNN_SOURCE_DIR "${PLAINVIDEO_RIFE_SOURCE_DIR}/subprojects/ncnn")
if(NOT EXISTS "${NCNN_SOURCE_DIR}/CMakeLists.txt")
  message(FATAL_ERROR
    "The pinned ncnn submodule is missing. Run scripts/bootstrap-rife-spike.ps1.")
endif()

# The spike is deliberately self-contained. It dynamically loads the installed
# Vulkan runtime through ncnn's simplevk path and statically links ncnn/glslang
# into the benchmark DLL. Nothing here is added to PlainVideo's Cargo or
# portable build yet.
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(NCNN_SHARED_LIB OFF CACHE BOOL "" FORCE)
set(NCNN_BUILD_BENCHMARK OFF CACHE BOOL "" FORCE)
set(NCNN_BENCHMARK ${PLAINVIDEO_RIFE_GPU_TIMESTAMP_DIAGNOSTICS}
    CACHE BOOL "" FORCE)
set(NCNN_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(NCNN_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(NCNN_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
set(NCNN_INSTALL_SDK OFF CACHE BOOL "" FORCE)
set(NCNN_PYTHON OFF CACHE BOOL "" FORCE)
set(NCNN_OPENMP OFF CACHE BOOL "" FORCE)
set(NCNN_VULKAN ON CACHE BOOL "" FORCE)
set(NCNN_SIMPLEVK ON CACHE BOOL "" FORCE)
set(NCNN_SYSTEM_GLSLANG OFF CACHE BOOL "" FORCE)
set(NCNN_VULKAN_ONLINE_SPIRV ON CACHE BOOL "" FORCE)
set(NCNN_PIXEL_ROTATE OFF CACHE BOOL "" FORCE)
set(NCNN_PIXEL_AFFINE OFF CACHE BOOL "" FORCE)
set(NCNN_PIXEL_DRAWING OFF CACHE BOOL "" FORCE)
set(NCNN_INT8 OFF CACHE BOOL "" FORCE)
set(NCNN_AVX OFF CACHE BOOL "" FORCE)
set(NCNN_AVX2 OFF CACHE BOOL "" FORCE)
set(NCNN_AVX512 OFF CACHE BOOL "" FORCE)
set(NCNN_AVX512VNNI OFF CACHE BOOL "" FORCE)
set(NCNN_AVX512BF16 OFF CACHE BOOL "" FORCE)
set(NCNN_AVX512FP16 OFF CACHE BOOL "" FORCE)
set(NCNN_AVXVNNI OFF CACHE BOOL "" FORCE)
set(NCNN_AVXVNNIINT8 OFF CACHE BOOL "" FORCE)
set(NCNN_FMA OFF CACHE BOOL "" FORCE)
set(NCNN_F16C OFF CACHE BOOL "" FORCE)
set(NCNN_XOP OFF CACHE BOOL "" FORCE)

# Match the maintained reference plugin's reduced ncnn layer set. RIFE 4.25-lite
# itself uses only a subset, while the extra utility layers remain pinned to
# the reference build's known-compatible layer inventory.
file(STRINGS "${NCNN_SOURCE_DIR}/src/CMakeLists.txt" NCNN_LAYER_DECLARATIONS
     REGEX "^[ \t]*ncnn_add_layer\\([A-Za-z0-9]+")
foreach(declaration IN LISTS NCNN_LAYER_DECLARATIONS)
  string(REGEX REPLACE ".*ncnn_add_layer\\(([A-Za-z0-9]+).*" "\\1"
         layer_class "${declaration}")
  string(TOLOWER "${layer_class}" layer_name)
  set("WITH_LAYER_${layer_name}" OFF CACHE BOOL "" FORCE)
endforeach()

set(RIFE_REQUIRED_NCNN_LAYERS
  concat convolution crop deconvolution eltwise flatten innerproduct input
  memorydata pooling prelu relu sigmoid slice split binaryop unaryop
  convolutiondepthwise padding interp packing cast pixelshuffle gemm clip
)
foreach(layer_name IN LISTS RIFE_REQUIRED_NCNN_LAYERS)
  set("WITH_LAYER_${layer_name}" ON CACHE BOOL "" FORCE)
endforeach()

add_subdirectory("${NCNN_SOURCE_DIR}" "${CMAKE_BINARY_DIR}/ncnn" EXCLUDE_FROM_ALL)

set(RIFE_EXTERNAL_SOURCES
  "${PLAINVIDEO_RIFE_SOURCE_DIR}/RIFE/warp.cpp"
)

add_library(plainvideo_rife SHARED
  src/checked_rife_v4.cpp
  src/plainvideo_rife.cpp
  ${RIFE_EXTERNAL_SOURCES}
)
if(PLAINVIDEO_RIFE_FUSED_CONCAT_DIAGNOSTICS)
  target_sources(plainvideo_rife PRIVATE src/rife_concat7.cpp)
endif()

target_compile_features(plainvideo_rife PRIVATE cxx_std_20)
target_compile_definitions(plainvideo_rife PRIVATE
  NOMINMAX
  PLAINVIDEO_RIFE_BUILD_DLL
)
if(PLAINVIDEO_RIFE_GPU_TIMESTAMP_DIAGNOSTICS)
  target_compile_definitions(plainvideo_rife PRIVATE
    PLAINVIDEO_RIFE_GPU_TIMESTAMP_DIAGNOSTICS=1)
endif()
if(PLAINVIDEO_RIFE_FUSED_CONCAT_DIAGNOSTICS)
  target_compile_definitions(plainvideo_rife PRIVATE
    PLAINVIDEO_RIFE_FUSED_CONCAT_DIAGNOSTICS=1)
endif()
target_include_directories(plainvideo_rife
  PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/include"
  PRIVATE "${PLAINVIDEO_RIFE_SOURCE_DIR}/RIFE"
)
target_link_libraries(plainvideo_rife PRIVATE ncnn)

if(MSVC)
  target_compile_options(plainvideo_rife PRIVATE /W4 /permissive- /EHsc)
  set_source_files_properties(${RIFE_EXTERNAL_SOURCES} PROPERTIES COMPILE_OPTIONS "/W0")
endif()

add_executable(plainvideo_rife_bench src/benchmark.cpp)
target_compile_features(plainvideo_rife_bench PRIVATE cxx_std_20)
target_compile_definitions(plainvideo_rife_bench PRIVATE NOMINMAX)
if(PLAINVIDEO_RIFE_FUSED_CONCAT_DIAGNOSTICS)
  target_compile_definitions(plainvideo_rife_bench PRIVATE
    PLAINVIDEO_RIFE_FUSED_CONCAT_DIAGNOSTICS=1)
endif()
target_link_libraries(plainvideo_rife_bench PRIVATE plainvideo_rife)

if(MSVC)
  target_compile_options(plainvideo_rife_bench PRIVATE /W4 /permissive- /EHsc)
endif()

foreach(target plainvideo_rife plainvideo_rife_bench)
  set_target_properties(${target} PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin"
    RUNTIME_OUTPUT_DIRECTORY_DEBUG "${CMAKE_BINARY_DIR}/bin/Debug"
    RUNTIME_OUTPUT_DIRECTORY_RELEASE "${CMAKE_BINARY_DIR}/bin/Release"
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin"
    ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib"
  )
endforeach()
