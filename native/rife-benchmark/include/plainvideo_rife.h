#ifndef PLAINVIDEO_RIFE_H
#define PLAINVIDEO_RIFE_H

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32)
#  if defined(PLAINVIDEO_RIFE_BUILD_DLL)
#    define PLAINVIDEO_RIFE_API __declspec(dllexport)
#  else
#    define PLAINVIDEO_RIFE_API __declspec(dllimport)
#  endif
#  define PLAINVIDEO_RIFE_CALL __cdecl
#else
#  define PLAINVIDEO_RIFE_API
#  define PLAINVIDEO_RIFE_CALL
#endif

#if defined(__cplusplus)
#  define PLAINVIDEO_RIFE_NOEXCEPT noexcept
#else
#  define PLAINVIDEO_RIFE_NOEXCEPT
#endif

#ifdef __cplusplus
extern "C" {
#endif

#define PLAINVIDEO_RIFE_ABI_VERSION 2u

typedef struct PlainVideoRifeHandle PlainVideoRifeHandle;

typedef enum PlainVideoRifeError {
    PLAINVIDEO_RIFE_OK = 0,
    PLAINVIDEO_RIFE_ERROR_INVALID_ARGUMENT = 1,
    PLAINVIDEO_RIFE_ERROR_VULKAN_UNAVAILABLE = 2,
    PLAINVIDEO_RIFE_ERROR_GPU_UNAVAILABLE = 3,
    PLAINVIDEO_RIFE_ERROR_MODEL_UNAVAILABLE = 4,
    PLAINVIDEO_RIFE_ERROR_INITIALIZATION_FAILED = 5,
    PLAINVIDEO_RIFE_ERROR_PROCESSING_FAILED = 6
} PlainVideoRifeError;

typedef enum PlainVideoRifeProcessStatus {
    PLAINVIDEO_RIFE_STATUS_GENERATED = 0,
    PLAINVIDEO_RIFE_STATUS_BYPASSED_SCENE_CHANGE = 1,
    PLAINVIDEO_RIFE_STATUS_BYPASSED_DISCONTINUITY = 2,
    PLAINVIDEO_RIFE_STATUS_BYPASSED_OVERLOAD = 3,
    PLAINVIDEO_RIFE_STATUS_BYPASSED_ERROR = 4
} PlainVideoRifeProcessStatus;

typedef enum PlainVideoRifeProcessFlags {
    PLAINVIDEO_RIFE_FLAG_NONE = 0,
    PLAINVIDEO_RIFE_FLAG_SCENE_CHANGE = 1u << 0,
    PLAINVIDEO_RIFE_FLAG_DISCONTINUITY = 1u << 1,
    PLAINVIDEO_RIFE_FLAG_OVERLOADED = 1u << 2
} PlainVideoRifeProcessFlags;

typedef enum PlainVideoRifePipelineMode {
    PLAINVIDEO_RIFE_PIPELINE_LEGACY_DUPLICATE_HOST = 0,
    PLAINVIDEO_RIFE_PIPELINE_PERSISTENT_HOST_BGRA8 = 1,
    PLAINVIDEO_RIFE_PIPELINE_PERSISTENT_VULKAN_STAGED = 2
} PlainVideoRifePipelineMode;

typedef enum PlainVideoRifeTimingFlags {
    PLAINVIDEO_RIFE_TIMING_HOST_INPUT = 1u << 0,
    PLAINVIDEO_RIFE_TIMING_GPU_ROUND_TRIP = 1u << 1,
    PLAINVIDEO_RIFE_TIMING_HOST_OUTPUT = 1u << 2,
    PLAINVIDEO_RIFE_TIMING_CORE_PATH = 1u << 3,
    PLAINVIDEO_RIFE_TIMING_FALLBACK_COPY = 1u << 4
} PlainVideoRifeTimingFlags;

typedef struct PlainVideoRifeConfig {
    uint32_t struct_size;
    uint32_t width;
    uint32_t height;
    int32_t gpu_index;
    uint32_t inference_threads;
    uint64_t deadline_us;
    uint32_t max_queue_depth;
    uint32_t overload_cooldown_frames;
    uint32_t pipeline_mode;
} PlainVideoRifeConfig;

typedef struct PlainVideoRifeRequest {
    uint32_t struct_size;
    const uint8_t* frame0_bgra8;
    uint32_t frame0_stride_bytes;
    const uint8_t* frame1_bgra8;
    uint32_t frame1_stride_bytes;
    uint8_t* output_bgra8;
    uint32_t output_stride_bytes;
    float timestep;
    uint32_t flags;
    uint32_t queue_depth;
} PlainVideoRifeRequest;

typedef struct PlainVideoRifeResult {
    uint32_t struct_size;
    uint32_t status;
    // Time through the generated-output attempt, before a possible fallback.
    uint64_t attempt_us;
    // Full synchronous return time, including a possible fallback copy.
    uint64_t elapsed_us;
    uint64_t host_input_prepare_us;
    // CPU wall time around upload, model execution, synchronized download, and
    // ncnn command setup. This is not a Vulkan timestamp or kernel-only timing.
    uint64_t gpu_round_trip_us;
    uint64_t host_output_pack_us;
    // Legacy: checked core total. Persistent host/Vulkan modes: direct BGRA
    // checked-core total, including their declared transfer boundary.
    uint64_t core_path_us;
    uint64_t fallback_copy_us;
    uint32_t deadline_exceeded;
    uint32_t timing_flags;
} PlainVideoRifeResult;

typedef struct PlainVideoRifeStats {
    uint32_t struct_size;
    uint64_t generated_frames;
    uint64_t bypassed_scene_changes;
    uint64_t bypassed_discontinuities;
    uint64_t bypassed_overload_frames;
    uint64_t missed_frames;
} PlainVideoRifeStats;

PLAINVIDEO_RIFE_API uint32_t PLAINVIDEO_RIFE_CALL
plainvideo_rife_abi_version(void) PLAINVIDEO_RIFE_NOEXCEPT;

PLAINVIDEO_RIFE_API int32_t PLAINVIDEO_RIFE_CALL
plainvideo_rife_create(const PlainVideoRifeConfig* config,
                       const char* model_directory_utf8,
                       PlainVideoRifeHandle** output_handle,
                       char* error_message,
                       size_t error_message_capacity) PLAINVIDEO_RIFE_NOEXCEPT;

// Lifetime contract: the caller must externally synchronize destruction.
// No API call may be in flight or begin after plainvideo_rife_destroy starts.
PLAINVIDEO_RIFE_API void PLAINVIDEO_RIFE_CALL
plainvideo_rife_destroy(PlainVideoRifeHandle* handle) PLAINVIDEO_RIFE_NOEXCEPT;

// Inputs remain caller-owned and immutable. All three frame ranges must be
// distinct and non-overlapping for the duration of the synchronous call.
// On PLAINVIDEO_RIFE_OK, status identifies a generated or valid source-frame
// fallback output. On any nonzero return, the caller must ignore result timing
// and output contents and select the source frame itself.
PLAINVIDEO_RIFE_API int32_t PLAINVIDEO_RIFE_CALL
plainvideo_rife_process(PlainVideoRifeHandle* handle,
                        const PlainVideoRifeRequest* request,
                        PlainVideoRifeResult* result,
                        char* error_message,
                        size_t error_message_capacity) PLAINVIDEO_RIFE_NOEXCEPT;

PLAINVIDEO_RIFE_API int32_t PLAINVIDEO_RIFE_CALL
plainvideo_rife_get_stats(const PlainVideoRifeHandle* handle,
                          PlainVideoRifeStats* output_stats) PLAINVIDEO_RIFE_NOEXCEPT;

PLAINVIDEO_RIFE_API int32_t PLAINVIDEO_RIFE_CALL
plainvideo_rife_reset_stats(PlainVideoRifeHandle* handle) PLAINVIDEO_RIFE_NOEXCEPT;

PLAINVIDEO_RIFE_API int32_t PLAINVIDEO_RIFE_CALL
plainvideo_rife_get_device_name(const PlainVideoRifeHandle* handle,
                                char* output_name,
                                size_t output_name_capacity) PLAINVIDEO_RIFE_NOEXCEPT;

#ifdef __cplusplus
}
#endif

#endif
