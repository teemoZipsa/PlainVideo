#include "plainvideo_rife.h"

#include "checked_rife_v4.h"

#include "gpu.h"

#include <Windows.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <limits>
#include <memory>
#include <mutex>
#include <new>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

namespace {

constexpr uint32_t kBytesPerPixel = 4;
constexpr float kRequiredTimestep = 0.5F;

std::mutex g_gpu_mutex;
uint32_t g_gpu_users = 0;

void write_error(char* destination, size_t capacity, std::string_view message) noexcept {
    if (destination == nullptr || capacity == 0) {
        return;
    }

    const size_t copied = std::min(capacity - 1, message.size());
    std::memcpy(destination, message.data(), copied);
    destination[copied] = '\0';
}

std::wstring utf8_to_wide(const char* text) {
    if (text == nullptr || text[0] == '\0') {
        return {};
    }

    const int required = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1,
                                              nullptr, 0);
    if (required <= 0) {
        return {};
    }

    std::wstring converted(static_cast<size_t>(required), L'\0');
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1,
                            converted.data(), required) <= 0) {
        return {};
    }
    converted.resize(static_cast<size_t>(required - 1));
    return converted;
}

bool acquire_gpu_runtime(std::string& error) {
    std::lock_guard lock(g_gpu_mutex);
    if (g_gpu_users == 0 && ncnn::create_gpu_instance() != 0) {
        error = "ncnn could not create a Vulkan GPU instance.";
        return false;
    }
    ++g_gpu_users;
    return true;
}

void release_gpu_runtime() noexcept {
    try {
        std::lock_guard lock(g_gpu_mutex);
        if (g_gpu_users == 0) {
            return;
        }
        --g_gpu_users;
        if (g_gpu_users == 0) {
            ncnn::destroy_gpu_instance();
        }
    } catch (...) {
        // A C ABI teardown path must never propagate a C++ synchronization
        // exception into its caller. The process is already shutting down the
        // spike context, so there is no safe secondary recovery action here.
    }
}

uint8_t float_to_byte(float value, bool& finite) {
    if (!std::isfinite(value)) {
        finite = false;
        return 0;
    }
    const float scaled = std::clamp(value, 0.0F, 1.0F) * 255.0F;
    return static_cast<uint8_t>(std::lround(scaled));
}

uint64_t elapsed_microseconds(std::chrono::steady_clock::time_point start,
                              std::chrono::steady_clock::time_point end) {
    return static_cast<uint64_t>(
        std::chrono::duration_cast<std::chrono::microseconds>(end - start).count());
}

} // namespace

struct PlainVideoRifeHandle {
    PlainVideoRifeConfig config{};
    int gpu_index = -1;
    std::string device_name;
    std::unique_ptr<CheckedRifeV4> rife;
    std::vector<float> workspace;
    PlainVideoRifeStats stats{};
    PlainVideoRifeGpuTimingDiagnostics last_gpu_timing{};
    uint32_t overload_bypass_remaining = 0;
    mutable std::mutex mutex;
};

namespace {

void copy_fallback(const PlainVideoRifeHandle& handle,
                   const PlainVideoRifeRequest& request) noexcept {
    const size_t row_bytes = static_cast<size_t>(handle.config.width) * kBytesPerPixel;
    for (uint32_t y = 0; y < handle.config.height; ++y) {
        const uint8_t* source = request.frame0_bgra8
            + static_cast<size_t>(y) * request.frame0_stride_bytes;
        uint8_t* destination = request.output_bgra8
            + static_cast<size_t>(y) * request.output_stride_bytes;
        std::memmove(destination, source, row_bytes);
    }
}

int32_t bypass(PlainVideoRifeHandle& handle,
               const PlainVideoRifeRequest& request,
               PlainVideoRifeResult& result,
               PlainVideoRifeProcessStatus status) {
    const auto copy_started = std::chrono::steady_clock::now();
    copy_fallback(handle, request);
    const auto copy_finished = std::chrono::steady_clock::now();
    result.status = static_cast<uint32_t>(status);
    result.attempt_us = 0;
    result.elapsed_us = elapsed_microseconds(copy_started, copy_finished);
    result.host_input_prepare_us = 0;
    result.gpu_round_trip_us = 0;
    result.host_output_pack_us = 0;
    result.core_path_us = 0;
    result.fallback_copy_us = result.elapsed_us;
    result.deadline_exceeded = 0;
    result.timing_flags = PLAINVIDEO_RIFE_TIMING_FALLBACK_COPY;

    switch (status) {
    case PLAINVIDEO_RIFE_STATUS_BYPASSED_SCENE_CHANGE:
        ++handle.stats.bypassed_scene_changes;
        break;
    case PLAINVIDEO_RIFE_STATUS_BYPASSED_DISCONTINUITY:
        ++handle.stats.bypassed_discontinuities;
        break;
    case PLAINVIDEO_RIFE_STATUS_BYPASSED_OVERLOAD:
        ++handle.stats.bypassed_overload_frames;
        break;
    case PLAINVIDEO_RIFE_STATUS_BYPASSED_ERROR:
        ++handle.stats.missed_frames;
        break;
    case PLAINVIDEO_RIFE_STATUS_GENERATED:
        break;
    }
    return PLAINVIDEO_RIFE_OK;
}

bool valid_request(const PlainVideoRifeHandle& handle,
                   const PlainVideoRifeRequest* request,
                   std::string& error) {
    if (request == nullptr || request->struct_size < sizeof(PlainVideoRifeRequest)) {
        error = "The RIFE request has an incompatible structure size.";
        return false;
    }
    if (request->frame0_bgra8 == nullptr || request->frame1_bgra8 == nullptr
        || request->output_bgra8 == nullptr) {
        error = "Two BGRA8 input frames and one output frame are required.";
        return false;
    }

    const uint64_t minimum_stride = static_cast<uint64_t>(handle.config.width)
        * kBytesPerPixel;
    if (request->frame0_stride_bytes < minimum_stride
        || request->frame1_stride_bytes < minimum_stride
        || request->output_stride_bytes < minimum_stride) {
        error = "Every BGRA8 stride must cover the configured frame width.";
        return false;
    }

    const auto frame_span = [&handle, minimum_stride](uint32_t stride) {
        return static_cast<uint64_t>(handle.config.height - 1) * stride
            + minimum_stride;
    };
    const auto overlaps = [](const uint8_t* first,
                             uint64_t first_size,
                             const uint8_t* second,
                             uint64_t second_size) {
        const uintptr_t first_start = reinterpret_cast<uintptr_t>(first);
        const uintptr_t second_start = reinterpret_cast<uintptr_t>(second);
        if (first_size > std::numeric_limits<uintptr_t>::max() - first_start
            || second_size > std::numeric_limits<uintptr_t>::max() - second_start) {
            return true;
        }
        const uintptr_t first_end = first_start + static_cast<uintptr_t>(first_size);
        const uintptr_t second_end = second_start + static_cast<uintptr_t>(second_size);
        return first_start < second_end && second_start < first_end;
    };
    const uint64_t frame0_span = frame_span(request->frame0_stride_bytes);
    const uint64_t frame1_span = frame_span(request->frame1_stride_bytes);
    const uint64_t output_span = frame_span(request->output_stride_bytes);
    if (overlaps(request->frame0_bgra8, frame0_span,
                 request->frame1_bgra8, frame1_span)
        || overlaps(request->frame0_bgra8, frame0_span,
                    request->output_bgra8, output_span)
        || overlaps(request->frame1_bgra8, frame1_span,
                    request->output_bgra8, output_span)) {
        error = "RIFE input and output frame ranges must not overlap.";
        return false;
    }
    if (!std::isfinite(request->timestep)
        || std::fabs(request->timestep - kRequiredTimestep) > 0.0001F) {
        error = "Slice 3A supports only a 0.5 timestep for 2x frame doubling.";
        return false;
    }
    return true;
}

} // namespace

extern "C" {

uint32_t PLAINVIDEO_RIFE_CALL plainvideo_rife_abi_version(void) noexcept {
    return PLAINVIDEO_RIFE_ABI_VERSION;
}

static int32_t plainvideo_rife_create_impl(
    const PlainVideoRifeConfig* config,
    const char* model_directory_utf8,
    PlainVideoRifeHandle** output_handle,
    char* error_message,
    size_t error_message_capacity) {
    if (output_handle != nullptr) {
        *output_handle = nullptr;
    }
    if (config == nullptr || output_handle == nullptr
        || config->struct_size < sizeof(PlainVideoRifeConfig)) {
        write_error(error_message, error_message_capacity,
                    "The RIFE configuration has an incompatible structure size.");
        return PLAINVIDEO_RIFE_ERROR_INVALID_ARGUMENT;
    }
    if (config->width != 1920 || config->height != 1080) {
        write_error(error_message, error_message_capacity,
                    "Slice 3A is intentionally limited to 1920x1080 SDR frames.");
        return PLAINVIDEO_RIFE_ERROR_INVALID_ARGUMENT;
    }
    if (config->inference_threads == 0) {
        write_error(error_message, error_message_capacity,
                    "inference_threads must be at least one.");
        return PLAINVIDEO_RIFE_ERROR_INVALID_ARGUMENT;
    }
    if (config->pipeline_mode != PLAINVIDEO_RIFE_PIPELINE_LEGACY_DUPLICATE_HOST
        && config->pipeline_mode != PLAINVIDEO_RIFE_PIPELINE_PERSISTENT_HOST_BGRA8
        && config->pipeline_mode != PLAINVIDEO_RIFE_PIPELINE_PERSISTENT_VULKAN_STAGED) {
        write_error(error_message, error_message_capacity,
                    "The RIFE pipeline mode is unsupported.");
        return PLAINVIDEO_RIFE_ERROR_INVALID_ARGUMENT;
    }

    const std::wstring model_directory = utf8_to_wide(model_directory_utf8);
    if (model_directory.empty() || model_directory.size() > 180) {
        write_error(error_message, error_message_capacity,
                    "The UTF-8 model directory is missing, invalid, or too long.");
        return PLAINVIDEO_RIFE_ERROR_MODEL_UNAVAILABLE;
    }
    const std::filesystem::path model_path(model_directory);
    const std::filesystem::path param_path = model_path / L"flownet.param";
    const std::filesystem::path binary_path = model_path / L"flownet.bin";
    std::error_code filesystem_error;
    if (!std::filesystem::is_regular_file(param_path, filesystem_error)
        || !std::filesystem::is_regular_file(binary_path, filesystem_error)
        || std::filesystem::file_size(param_path, filesystem_error) == 0
        || std::filesystem::file_size(binary_path, filesystem_error) == 0) {
        write_error(error_message, error_message_capacity,
                    "The pinned RIFE 4.25-lite flownet.param/flownet.bin files are unavailable.");
        return PLAINVIDEO_RIFE_ERROR_MODEL_UNAVAILABLE;
    }

    std::string runtime_error;
    if (!acquire_gpu_runtime(runtime_error)) {
        write_error(error_message, error_message_capacity, runtime_error);
        return PLAINVIDEO_RIFE_ERROR_VULKAN_UNAVAILABLE;
    }

    try {
        const int gpu_count = ncnn::get_gpu_count();
        int gpu_index = config->gpu_index;
        if (gpu_index < 0) {
            gpu_index = ncnn::get_default_gpu_index();
        }
        if (gpu_index < 0 || gpu_index >= gpu_count) {
            release_gpu_runtime();
            write_error(error_message, error_message_capacity,
                        "The selected Vulkan GPU index is unavailable.");
            return PLAINVIDEO_RIFE_ERROR_GPU_UNAVAILABLE;
        }

        auto handle = std::make_unique<PlainVideoRifeHandle>();
        handle->config = *config;
        handle->gpu_index = gpu_index;
        handle->device_name = ncnn::get_gpu_info(gpu_index).device_name();
        handle->stats.struct_size = sizeof(PlainVideoRifeStats);
        handle->last_gpu_timing.struct_size =
            sizeof(PlainVideoRifeGpuTimingDiagnostics);

        if (config->pipeline_mode == PLAINVIDEO_RIFE_PIPELINE_LEGACY_DUPLICATE_HOST) {
            const size_t pixels = static_cast<size_t>(config->width) * config->height;
            if (pixels > std::numeric_limits<size_t>::max() / (9 * sizeof(float))) {
                throw std::bad_alloc();
            }
            handle->workspace.resize(pixels * 9);
        }
        handle->rife = std::make_unique<CheckedRifeV4>(
            gpu_index,
            static_cast<int>(config->inference_threads),
            config->pipeline_mode
                == PLAINVIDEO_RIFE_PIPELINE_PERSISTENT_VULKAN_STAGED);
        std::string core_error;
        if (handle->rife->load(model_directory, core_error) != 0) {
            throw std::runtime_error(core_error.empty()
                                         ? "The checked RIFE model loader returned an error."
                                         : core_error);
        }

        *output_handle = handle.release();
        write_error(error_message, error_message_capacity, "");
        return PLAINVIDEO_RIFE_OK;
    } catch (const std::exception& error) {
        release_gpu_runtime();
        write_error(error_message, error_message_capacity,
                    std::string("RIFE initialization failed: ") + error.what());
        return PLAINVIDEO_RIFE_ERROR_INITIALIZATION_FAILED;
    } catch (...) {
        release_gpu_runtime();
        write_error(error_message, error_message_capacity,
                    "RIFE initialization failed with an unknown error.");
        return PLAINVIDEO_RIFE_ERROR_INITIALIZATION_FAILED;
    }
}

static void plainvideo_rife_destroy_impl(PlainVideoRifeHandle* handle) {
    if (handle == nullptr) {
        return;
    }
    delete handle;
    release_gpu_runtime();
}

static int32_t plainvideo_rife_process_impl(
    PlainVideoRifeHandle* handle,
    const PlainVideoRifeRequest* request,
    PlainVideoRifeResult* result,
    char* error_message,
    size_t error_message_capacity) {
    if (handle == nullptr || result == nullptr
        || result->struct_size < sizeof(PlainVideoRifeResult)) {
        write_error(error_message, error_message_capacity,
                    "A valid RIFE handle and result structure are required.");
        return PLAINVIDEO_RIFE_ERROR_INVALID_ARGUMENT;
    }

    std::string validation_error;
    if (!valid_request(*handle, request, validation_error)) {
        write_error(error_message, error_message_capacity, validation_error);
        return PLAINVIDEO_RIFE_ERROR_INVALID_ARGUMENT;
    }

    std::lock_guard lock(handle->mutex);
    const uint32_t result_struct_size = result->struct_size;
    *result = {};
    result->struct_size = result_struct_size;
    result->status = PLAINVIDEO_RIFE_STATUS_BYPASSED_ERROR;
    handle->last_gpu_timing = {};
    handle->last_gpu_timing.struct_size =
        sizeof(PlainVideoRifeGpuTimingDiagnostics);

    if ((request->flags & PLAINVIDEO_RIFE_FLAG_DISCONTINUITY) != 0) {
        write_error(error_message, error_message_capacity, "");
        return bypass(*handle, *request, *result,
                      PLAINVIDEO_RIFE_STATUS_BYPASSED_DISCONTINUITY);
    }
    if ((request->flags & PLAINVIDEO_RIFE_FLAG_SCENE_CHANGE) != 0) {
        write_error(error_message, error_message_capacity, "");
        return bypass(*handle, *request, *result,
                      PLAINVIDEO_RIFE_STATUS_BYPASSED_SCENE_CHANGE);
    }
    if ((request->flags & PLAINVIDEO_RIFE_FLAG_OVERLOADED) != 0
        || request->queue_depth > handle->config.max_queue_depth
        || handle->overload_bypass_remaining > 0) {
        if (handle->overload_bypass_remaining > 0) {
            --handle->overload_bypass_remaining;
        }
        write_error(error_message, error_message_capacity, "");
        return bypass(*handle, *request, *result,
                      PLAINVIDEO_RIFE_STATUS_BYPASSED_OVERLOAD);
    }

    const auto started = std::chrono::steady_clock::now();
    int process_result = -1;
    std::string core_error;
    bool finite = true;
    if (handle->config.pipeline_mode
        == PLAINVIDEO_RIFE_PIPELINE_LEGACY_DUPLICATE_HOST) {
        const size_t pixels = static_cast<size_t>(handle->config.width)
            * handle->config.height;
        float* frame0_r = handle->workspace.data();
        float* frame0_g = frame0_r + pixels;
        float* frame0_b = frame0_g + pixels;
        float* frame1_r = frame0_b + pixels;
        float* frame1_g = frame1_r + pixels;
        float* frame1_b = frame1_g + pixels;
        float* output_r = frame1_b + pixels;
        float* output_g = output_r + pixels;
        float* output_b = output_g + pixels;

        for (uint32_t y = 0; y < handle->config.height; ++y) {
            const uint8_t* source0 = request->frame0_bgra8
                + static_cast<size_t>(y) * request->frame0_stride_bytes;
            const uint8_t* source1 = request->frame1_bgra8
                + static_cast<size_t>(y) * request->frame1_stride_bytes;
            const size_t row = static_cast<size_t>(y) * handle->config.width;
            for (uint32_t x = 0; x < handle->config.width; ++x) {
                const size_t pixel = row + x;
                const size_t byte = static_cast<size_t>(x) * kBytesPerPixel;
                frame0_b[pixel] = static_cast<float>(source0[byte]) / 255.0F;
                frame0_g[pixel] = static_cast<float>(source0[byte + 1]) / 255.0F;
                frame0_r[pixel] = static_cast<float>(source0[byte + 2]) / 255.0F;
                frame1_b[pixel] = static_cast<float>(source1[byte]) / 255.0F;
                frame1_g[pixel] = static_cast<float>(source1[byte + 1]) / 255.0F;
                frame1_r[pixel] = static_cast<float>(source1[byte + 2]) / 255.0F;
            }
        }
        const auto input_finished = std::chrono::steady_clock::now();
        result->host_input_prepare_us = elapsed_microseconds(started, input_finished);
        result->timing_flags |= PLAINVIDEO_RIFE_TIMING_HOST_INPUT;

        try {
            process_result = handle->rife->process(
                frame0_r, frame0_g, frame0_b,
                frame1_r, frame1_g, frame1_b,
                output_r, output_g, output_b,
                static_cast<int>(handle->config.width),
                static_cast<int>(handle->config.height),
                static_cast<ptrdiff_t>(handle->config.width),
                request->timestep,
                core_error);
        } catch (...) {
            process_result = -1;
        }
        const auto core_finished = std::chrono::steady_clock::now();
        result->core_path_us = elapsed_microseconds(input_finished, core_finished);
        result->timing_flags |= PLAINVIDEO_RIFE_TIMING_CORE_PATH;

        if (process_result == 0) {
            for (uint32_t y = 0; y < handle->config.height; ++y) {
                uint8_t* destination = request->output_bgra8
                    + static_cast<size_t>(y) * request->output_stride_bytes;
                const size_t row = static_cast<size_t>(y) * handle->config.width;
                for (uint32_t x = 0; x < handle->config.width; ++x) {
                    const size_t pixel = row + x;
                    const size_t byte = static_cast<size_t>(x) * kBytesPerPixel;
                    destination[byte] = float_to_byte(output_b[pixel], finite);
                    destination[byte + 1] = float_to_byte(output_g[pixel], finite);
                    destination[byte + 2] = float_to_byte(output_r[pixel], finite);
                    destination[byte + 3] = 255;
                }
            }
        }
        const auto output_finished = std::chrono::steady_clock::now();
        result->host_output_pack_us = elapsed_microseconds(
            core_finished, output_finished);
        result->timing_flags |= PLAINVIDEO_RIFE_TIMING_HOST_OUTPUT;
    } else {
        CheckedRifeV4Timings timings{};
        try {
            if (handle->config.pipeline_mode
                == PLAINVIDEO_RIFE_PIPELINE_PERSISTENT_VULKAN_STAGED) {
                process_result = handle->rife->process_bgra8_persistent_vulkan(
                    request->frame0_bgra8,
                    static_cast<ptrdiff_t>(request->frame0_stride_bytes),
                    request->frame1_bgra8,
                    static_cast<ptrdiff_t>(request->frame1_stride_bytes),
                    request->output_bgra8,
                    static_cast<ptrdiff_t>(request->output_stride_bytes),
                    request->timestep,
                    timings,
                    core_error);
            } else {
                process_result = handle->rife->process_bgra8(
                    request->frame0_bgra8,
                    static_cast<ptrdiff_t>(request->frame0_stride_bytes),
                    request->frame1_bgra8,
                    static_cast<ptrdiff_t>(request->frame1_stride_bytes),
                    request->output_bgra8,
                    static_cast<ptrdiff_t>(request->output_stride_bytes),
                    request->timestep,
                    timings,
                    core_error);
            }
        } catch (...) {
            process_result = -1;
        }
        result->host_input_prepare_us = timings.host_input_prepare_us;
        result->gpu_round_trip_us = timings.gpu_path_us;
        result->host_output_pack_us = timings.host_output_pack_us;
        result->core_path_us = timings.core_path_us;
        result->timing_flags |= PLAINVIDEO_RIFE_TIMING_HOST_INPUT
            | PLAINVIDEO_RIFE_TIMING_GPU_ROUND_TRIP
            | PLAINVIDEO_RIFE_TIMING_HOST_OUTPUT
            | PLAINVIDEO_RIFE_TIMING_CORE_PATH;
        handle->last_gpu_timing.available =
            timings.gpu_timestamps_available ? 1U : 0U;
        handle->last_gpu_timing.upload_preprocess_ns =
            timings.gpu_upload_preprocess_ns;
        handle->last_gpu_timing.model_ns = timings.gpu_model_ns;
        handle->last_gpu_timing.postprocess_ns =
            timings.gpu_postprocess_ns;
        handle->last_gpu_timing.compute_total_ns =
            timings.gpu_compute_total_ns;
        handle->last_gpu_timing.fused_concat_calls =
            timings.gpu_fused_concat_calls;
        handle->last_gpu_timing.fused_concat_fallback_calls =
            timings.gpu_fused_concat_fallback_calls;
        handle->last_gpu_timing.hotspot_count =
            std::min<uint32_t>(
                timings.gpu_hotspot_count,
                PLAINVIDEO_RIFE_GPU_HOTSPOT_CAPACITY);
        for (uint32_t index = 0;
             index < handle->last_gpu_timing.hotspot_count;
             ++index) {
            write_error(
                handle->last_gpu_timing.hotspot_labels[index],
                PLAINVIDEO_RIFE_GPU_HOTSPOT_LABEL_CAPACITY,
                timings.gpu_hotspot_labels[index]);
            handle->last_gpu_timing.hotspot_duration_ns[index] =
                timings.gpu_hotspot_duration_ns[index];
        }
    }

    const auto attempt_finished = std::chrono::steady_clock::now();
    result->attempt_us = elapsed_microseconds(started, attempt_finished);
    result->elapsed_us = result->attempt_us;

    if (process_result != 0 || !finite) {
        const std::string detail = core_error.empty()
            ? "RIFE inference failed"
            : std::string("RIFE inference failed: ") + core_error;
        write_error(error_message, error_message_capacity,
                    detail + "; the previous source frame was preserved.");
        const auto fallback_started = std::chrono::steady_clock::now();
        copy_fallback(*handle, *request);
        const auto fallback_finished = std::chrono::steady_clock::now();
        result->fallback_copy_us = elapsed_microseconds(
            fallback_started, fallback_finished);
        result->elapsed_us = elapsed_microseconds(started, fallback_finished);
        result->timing_flags |= PLAINVIDEO_RIFE_TIMING_FALLBACK_COPY;
        result->status = PLAINVIDEO_RIFE_STATUS_BYPASSED_ERROR;
        ++handle->stats.missed_frames;
        return PLAINVIDEO_RIFE_ERROR_PROCESSING_FAILED;
    }

    result->deadline_exceeded = handle->config.deadline_us > 0
        && result->attempt_us > handle->config.deadline_us;
    if (result->deadline_exceeded) {
        const auto fallback_started = std::chrono::steady_clock::now();
        copy_fallback(*handle, *request);
        const auto fallback_finished = std::chrono::steady_clock::now();
        result->fallback_copy_us = elapsed_microseconds(
            fallback_started, fallback_finished);
        result->elapsed_us = elapsed_microseconds(started, fallback_finished);
        result->timing_flags |= PLAINVIDEO_RIFE_TIMING_FALLBACK_COPY;
        result->status = PLAINVIDEO_RIFE_STATUS_BYPASSED_OVERLOAD;
        ++handle->stats.bypassed_overload_frames;
        if (handle->config.overload_cooldown_frames > 0) {
            handle->overload_bypass_remaining = handle->config.overload_cooldown_frames;
        }
    } else {
        result->status = PLAINVIDEO_RIFE_STATUS_GENERATED;
        ++handle->stats.generated_frames;
    }
    write_error(error_message, error_message_capacity, "");
    return PLAINVIDEO_RIFE_OK;
}

static int32_t plainvideo_rife_get_stats_impl(
    const PlainVideoRifeHandle* handle,
    PlainVideoRifeStats* output_stats) {
    if (handle == nullptr || output_stats == nullptr
        || output_stats->struct_size < sizeof(PlainVideoRifeStats)) {
        return PLAINVIDEO_RIFE_ERROR_INVALID_ARGUMENT;
    }
    std::lock_guard lock(handle->mutex);
    *output_stats = handle->stats;
    return PLAINVIDEO_RIFE_OK;
}

static int32_t plainvideo_rife_reset_stats_impl(PlainVideoRifeHandle* handle) {
    if (handle == nullptr) {
        return PLAINVIDEO_RIFE_ERROR_INVALID_ARGUMENT;
    }
    std::lock_guard lock(handle->mutex);
    handle->stats = {};
    handle->stats.struct_size = sizeof(PlainVideoRifeStats);
    handle->overload_bypass_remaining = 0;
    return PLAINVIDEO_RIFE_OK;
}

static int32_t plainvideo_rife_get_last_gpu_timing_impl(
    const PlainVideoRifeHandle* handle,
    PlainVideoRifeGpuTimingDiagnostics* output_timing) {
    if (handle == nullptr || output_timing == nullptr
        || output_timing->struct_size
            < sizeof(PlainVideoRifeGpuTimingDiagnostics)) {
        return PLAINVIDEO_RIFE_ERROR_INVALID_ARGUMENT;
    }
    std::lock_guard lock(handle->mutex);
    *output_timing = handle->last_gpu_timing;
    return PLAINVIDEO_RIFE_OK;
}

static int32_t plainvideo_rife_get_device_name_impl(
    const PlainVideoRifeHandle* handle,
    char* output_name,
    size_t output_name_capacity) {
    if (handle == nullptr || output_name == nullptr || output_name_capacity == 0) {
        return PLAINVIDEO_RIFE_ERROR_INVALID_ARGUMENT;
    }
    std::lock_guard lock(handle->mutex);
    write_error(output_name, output_name_capacity, handle->device_name);
    return PLAINVIDEO_RIFE_OK;
}

int32_t PLAINVIDEO_RIFE_CALL
plainvideo_rife_create(const PlainVideoRifeConfig* config,
                       const char* model_directory_utf8,
                       PlainVideoRifeHandle** output_handle,
                       char* error_message,
                       size_t error_message_capacity) noexcept {
    try {
        return plainvideo_rife_create_impl(
            config, model_directory_utf8, output_handle,
            error_message, error_message_capacity);
    } catch (const std::bad_alloc&) {
        if (output_handle != nullptr) {
            *output_handle = nullptr;
        }
        write_error(error_message, error_message_capacity,
                    "RIFE initialization ran out of memory.");
        return PLAINVIDEO_RIFE_ERROR_INITIALIZATION_FAILED;
    } catch (...) {
        if (output_handle != nullptr) {
            *output_handle = nullptr;
        }
        write_error(error_message, error_message_capacity,
                    "RIFE initialization failed with an unexpected native exception.");
        return PLAINVIDEO_RIFE_ERROR_INITIALIZATION_FAILED;
    }
}

void PLAINVIDEO_RIFE_CALL
plainvideo_rife_destroy(PlainVideoRifeHandle* handle) noexcept {
    try {
        plainvideo_rife_destroy_impl(handle);
    } catch (...) {
        // Destruction has no error channel. The externally synchronized
        // lifetime contract and noexcept C boundary take precedence here.
    }
}

int32_t PLAINVIDEO_RIFE_CALL
plainvideo_rife_process(PlainVideoRifeHandle* handle,
                        const PlainVideoRifeRequest* request,
                        PlainVideoRifeResult* result,
                        char* error_message,
                        size_t error_message_capacity) noexcept {
    try {
        return plainvideo_rife_process_impl(
            handle, request, result, error_message, error_message_capacity);
    } catch (const std::bad_alloc&) {
        write_error(error_message, error_message_capacity,
                    "RIFE processing ran out of memory; the caller must use the source frame.");
        return PLAINVIDEO_RIFE_ERROR_PROCESSING_FAILED;
    } catch (...) {
        write_error(error_message, error_message_capacity,
                    "RIFE processing failed with an unexpected native exception; "
                    "the caller must use the source frame.");
        return PLAINVIDEO_RIFE_ERROR_PROCESSING_FAILED;
    }
}

int32_t PLAINVIDEO_RIFE_CALL
plainvideo_rife_get_stats(const PlainVideoRifeHandle* handle,
                          PlainVideoRifeStats* output_stats) noexcept {
    try {
        return plainvideo_rife_get_stats_impl(handle, output_stats);
    } catch (...) {
        return PLAINVIDEO_RIFE_ERROR_PROCESSING_FAILED;
    }
}

int32_t PLAINVIDEO_RIFE_CALL
plainvideo_rife_reset_stats(PlainVideoRifeHandle* handle) noexcept {
    try {
        return plainvideo_rife_reset_stats_impl(handle);
    } catch (...) {
        return PLAINVIDEO_RIFE_ERROR_PROCESSING_FAILED;
    }
}

int32_t PLAINVIDEO_RIFE_CALL
plainvideo_rife_get_last_gpu_timing(
    const PlainVideoRifeHandle* handle,
    PlainVideoRifeGpuTimingDiagnostics* output_timing) noexcept {
    try {
        return plainvideo_rife_get_last_gpu_timing_impl(
            handle, output_timing);
    } catch (...) {
        return PLAINVIDEO_RIFE_ERROR_PROCESSING_FAILED;
    }
}

int32_t PLAINVIDEO_RIFE_CALL
plainvideo_rife_get_device_name(const PlainVideoRifeHandle* handle,
                                char* output_name,
                                size_t output_name_capacity) noexcept {
    try {
        return plainvideo_rife_get_device_name_impl(
            handle, output_name, output_name_capacity);
    } catch (...) {
        if (output_name != nullptr && output_name_capacity > 0) {
            output_name[0] = '\0';
        }
        return PLAINVIDEO_RIFE_ERROR_PROCESSING_FAILED;
    }
}

} // extern "C"
