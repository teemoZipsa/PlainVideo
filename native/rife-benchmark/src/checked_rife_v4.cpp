// Adapted from VapourSynth-RIFE-ncnn-Vulkan RIFE/rife.cpp at the pinned
// c3ec6aabc07c8fa37a4f58d7fed9e2ad1fc1b13f commit.
// Copyright (c) 2021-2022 HolyWu; MIT License. See THIRD_PARTY_NOTICES.md.

#include "checked_rife_v4.h"

#include "command.h"
#include "gpu.h"
#include "net.h"
#include "pipeline.h"
#include "rife_ops.h"

#include "rife_postproc.comp.hex.h"
#include "rife_preproc.comp.hex.h"
#include "rife_v4_timestep.comp.hex.h"
#include "rife_postproc_bgra8.h"
#include "rife_preproc_bgra8.h"
#if defined(PLAINVIDEO_RIFE_FUSED_CONCAT_DIAGNOSTICS)
#include "rife_concat7.h"
#endif

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <cstdio>
#include <filesystem>
#include <limits>
#include <memory>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

DEFINE_LAYER_CREATOR(Warp)

namespace {

constexpr int kPadding = 128;
constexpr float kTimestep = 0.5F;
constexpr int kDirectWidth = 1920;
constexpr int kDirectHeight = 1080;
constexpr int kChannels = 3;
constexpr int kBgraChannels = 4;
#if defined(PLAINVIDEO_RIFE_GPU_TIMESTAMP_DIAGNOSTICS)
constexpr std::uint32_t kGpuTimestampCount = 4;
#endif

std::mutex g_shader_compile_mutex;

bool development_environment_flag(const char* name) noexcept {
    char* value = nullptr;
    size_t length = 0;
    if (_dupenv_s(&value, &length, name) != 0
        || value == nullptr) {
        return false;
    }
    const std::unique_ptr<char, decltype(&std::free)> owned(value, &std::free);
    return std::strcmp(value, "1") == 0;
}

bool development_fp16_arithmetic_requested() noexcept {
    return development_environment_flag(
        "PLAINVIDEO_RIFE_FP16_ARITHMETIC");
}

#if defined(PLAINVIDEO_RIFE_FUSED_CONCAT_DIAGNOSTICS)
bool development_fused_concat_requested() noexcept {
    return development_environment_flag(
        "PLAINVIDEO_RIFE_FUSED_CONCAT");
}
#endif

int fail(std::string& error, std::string message) {
    error = std::move(message);
    return -1;
}

std::string with_code(const char* operation, int code) {
    return std::string(operation) + " failed with ncnn status "
        + std::to_string(code) + ".";
}

#if defined(PLAINVIDEO_RIFE_GPU_TIMESTAMP_DIAGNOSTICS)
std::uint64_t timestamp_duration_ns(std::uint64_t start,
                                    std::uint64_t end,
                                    float timestamp_period_ns) {
    if (end < start || timestamp_period_ns <= 0.0F) {
        return 0;
    }
    const long double duration = static_cast<long double>(end - start)
        * static_cast<long double>(timestamp_period_ns);
    if (duration >= static_cast<long double>(
            std::numeric_limits<std::uint64_t>::max())) {
        return std::numeric_limits<std::uint64_t>::max();
    }
    return static_cast<std::uint64_t>(duration + 0.5L);
}
#endif

int load_net_file(ncnn::Net& net,
                  const std::filesystem::path& path,
                  bool parameter_file,
                  std::string& error) {
    FILE* raw_file = nullptr;
    const errno_t open_result = _wfopen_s(&raw_file, path.c_str(), L"rb");
    if (open_result != 0 || raw_file == nullptr) {
        return fail(error, std::string("Could not open RIFE model file: ")
                    + path.filename().string());
    }

    const std::unique_ptr<FILE, int (*)(FILE*)> file(raw_file, &std::fclose);
    const int result = parameter_file
        ? net.load_param(file.get())
        : net.load_model(file.get());
    if (result != 0) {
        return fail(error,
                    with_code(parameter_file ? "flownet parameter load"
                                             : "flownet weight load",
                              result));
    }
    return 0;
}

int create_pipeline(const ncnn::VulkanDevice* device,
                    const char* shader_data,
                    int shader_size,
                    const ncnn::Option& option,
                    int local_x,
                    int local_y,
                    int local_z,
                    const std::vector<ncnn::vk_specialization_type>& specializations,
                    std::unique_ptr<ncnn::Pipeline>& output,
                    const char* label,
                    std::string& error) {
    std::vector<uint32_t> spirv;
    int compile_result = 0;
    {
        std::lock_guard lock(g_shader_compile_mutex);
        compile_result = ncnn::compile_spirv_module(
            shader_data, shader_size, option, spirv);
    }
    if (compile_result != 0 || spirv.empty()) {
        return fail(error, with_code(label, compile_result));
    }

    auto pipeline = std::make_unique<ncnn::Pipeline>(device);
    pipeline->set_optimal_local_size_xyz(local_x, local_y, local_z);
    const int create_result = pipeline->create(
        spirv.data(), spirv.size() * sizeof(uint32_t), specializations);
    if (create_result != 0) {
        return fail(error, with_code(label, create_result));
    }

    output = std::move(pipeline);
    return 0;
}

class VulkanAllocatorLease {
public:
    explicit VulkanAllocatorLease(const ncnn::VulkanDevice* device)
        : device_(device) {
    }

    ~VulkanAllocatorLease() {
        if (staging_ != nullptr) {
            device_->reclaim_staging_allocator(staging_);
        }
        if (blob_ != nullptr) {
            device_->reclaim_blob_allocator(blob_);
        }
    }

    VulkanAllocatorLease(const VulkanAllocatorLease&) = delete;
    VulkanAllocatorLease& operator=(const VulkanAllocatorLease&) = delete;

    int acquire(std::string& error) {
        blob_ = device_->acquire_blob_allocator();
        if (blob_ == nullptr) {
            return fail(error, "ncnn could not acquire a Vulkan blob allocator.");
        }
        staging_ = device_->acquire_staging_allocator();
        if (staging_ == nullptr) {
            return fail(error, "ncnn could not acquire a Vulkan staging allocator.");
        }
        return 0;
    }

    ncnn::VkAllocator* blob() const {
        return blob_;
    }

    ncnn::VkAllocator* staging() const {
        return staging_;
    }

private:
    const ncnn::VulkanDevice* device_;
    ncnn::VkAllocator* blob_ = nullptr;
    ncnn::VkAllocator* staging_ = nullptr;
};

// Fixed resources for the staged host/Vulkan candidate. The explicit
// destructor order is important: VkCompute can retain command-time references
// to buffers, and every VkMat must return its allocation before the allocator
// leases are returned to the VulkanDevice pool.
class PersistentVulkanResources;

class PersistentRecordingGuard {
public:
    explicit PersistentRecordingGuard(
        PersistentVulkanResources& resources) noexcept;
    ~PersistentRecordingGuard() noexcept;

    PersistentRecordingGuard(const PersistentRecordingGuard&) = delete;
    PersistentRecordingGuard& operator=(const PersistentRecordingGuard&) = delete;

    void dismiss() noexcept {
        active_ = false;
    }

private:
    PersistentVulkanResources* resources_ = nullptr;
    bool active_ = true;
};

class PersistentVulkanResources {
public:
    explicit PersistentVulkanResources(const ncnn::VulkanDevice* device)
        : device(device) {
    }

    ~PersistentVulkanResources() {
        command.reset();

        download_staging.release();
        output_gpu.release();
        timestep_gpu.release();
        input1_padded.release();
        input0_padded.release();
        input1_gpu.release();
        input0_gpu.release();
        upload1_staging.release();
        upload0_staging.release();

        if (staging_allocator != nullptr) {
            device->reclaim_staging_allocator(staging_allocator);
            staging_allocator = nullptr;
        }
        if (blob_allocator != nullptr) {
            device->reclaim_blob_allocator(blob_allocator);
            blob_allocator = nullptr;
        }
    }

    PersistentVulkanResources(const PersistentVulkanResources&) = delete;
    PersistentVulkanResources& operator=(const PersistentVulkanResources&) = delete;

    int initialize(const ncnn::Option& base_option,
                   const ncnn::Pipeline* timestep_pipeline,
                   std::size_t flownet_layer_count,
                   std::string& error) {
        blob_allocator = device->acquire_blob_allocator();
        if (blob_allocator == nullptr) {
            return fail(error,
                        "ncnn could not acquire the persistent Vulkan blob allocator.");
        }
        staging_allocator = device->acquire_staging_allocator();
        if (staging_allocator == nullptr) {
            return fail(error,
                        "ncnn could not acquire the persistent Vulkan staging allocator.");
        }

        option = base_option;
        option.blob_vkallocator = blob_allocator;
        option.workspace_vkallocator = blob_allocator;
        option.staging_vkallocator = staging_allocator;

        constexpr int padded_width =
            (kDirectWidth + kPadding - 1) / kPadding * kPadding;
        constexpr int padded_height =
            (kDirectHeight + kPadding - 1) / kPadding * kPadding;
        const size_t storage_element_size = option.use_fp16_storage ? 2U : 4U;

        upload0_staging.create(kDirectWidth, kDirectHeight, 1,
                               sizeof(std::uint32_t), 1, staging_allocator);
        upload1_staging.create(kDirectWidth, kDirectHeight, 1,
                               sizeof(std::uint32_t), 1, staging_allocator);
        download_staging.create(kDirectWidth, kDirectHeight, 1,
                                sizeof(std::uint32_t), 1, staging_allocator);

        input0_gpu.create(kDirectWidth, kDirectHeight, 1,
                          sizeof(std::uint32_t), 1, blob_allocator);
        input1_gpu.create(kDirectWidth, kDirectHeight, 1,
                          sizeof(std::uint32_t), 1, blob_allocator);
        input0_padded.create(padded_width, padded_height, kChannels,
                             storage_element_size, 1, blob_allocator);
        input1_padded.create(padded_width, padded_height, kChannels,
                             storage_element_size, 1, blob_allocator);
        timestep_gpu.create(padded_width, padded_height, 1,
                            storage_element_size, 1, blob_allocator);
        output_gpu.create(kDirectWidth, kDirectHeight, 1,
                          sizeof(std::uint32_t), 1, blob_allocator);

        if (upload0_staging.empty() || upload1_staging.empty()
            || download_staging.empty() || input0_gpu.empty()
            || input1_gpu.empty() || input0_padded.empty()
            || input1_padded.empty() || timestep_gpu.empty()
            || output_gpu.empty()) {
            return fail(error,
                        "ncnn could not allocate the persistent staged Vulkan frames.");
        }
        if (upload0_staging.mapped_ptr() == nullptr
            || upload1_staging.mapped_ptr() == nullptr
            || download_staging.mapped_ptr() == nullptr) {
            return fail(error,
                        "ncnn did not provide mapped persistent Vulkan staging frames.");
        }

        command = std::make_unique<ncnn::VkCompute>(device);
        if (timestep_pipeline == nullptr) {
            return fail(error, "The persistent Vulkan timestep pipeline is unavailable.");
        }

        PersistentRecordingGuard recording_guard(*this);
        std::vector<ncnn::VkMat> bindings(1);
        bindings[0] = timestep_gpu;
        std::vector<ncnn::vk_constant_type> constants(4);
        constants[0].i = timestep_gpu.w;
        constants[1].i = timestep_gpu.h;
        constants[2].i = static_cast<int>(timestep_gpu.cstep);
        constants[3].f = kTimestep;
        command->record_pipeline(timestep_pipeline, bindings, constants,
                                 timestep_gpu);

        const int submit_result = submit_and_reset(
            "Persistent Vulkan timestep submission", error);
        recording_guard.dismiss();
        if (submit_result != 0) {
            return -1;
        }

#if defined(PLAINVIDEO_RIFE_GPU_TIMESTAMP_DIAGNOSTICS)
        if (flownet_layer_count
            > (std::numeric_limits<std::uint32_t>::max()
               - kGpuTimestampCount) / 2U) {
            return fail(error,
                        "The RIFE network has too many layers for Vulkan timestamp diagnostics.");
        }
        timestamp_query_base =
            static_cast<std::uint32_t>(flownet_layer_count * 2U);
        const std::uint32_t query_count =
            timestamp_query_base + kGpuTimestampCount;
        if (command->create_query_pool(query_count) != 0) {
            return fail(error,
                        "ncnn could not create the Vulkan timestamp query pool.");
        }
        timestamp_results.resize(query_count);
        timestamp_period_ns = device->info.timestamp_period();
        if (timestamp_period_ns <= 0.0F) {
            return fail(error,
                        "The Vulkan device reported an invalid timestamp period.");
        }
#else
        (void)flownet_layer_count;
#endif

        return 0;
    }

    int abort_recording(std::string message, std::string& error) {
        abandon_recording_noexcept();
        if (poisoned) {
            if (!poison_reason.empty()) {
                message += " ";
                message += poison_reason;
            }
            return fail(error, std::move(message));
        }
        return fail(error, std::move(message));
    }

    int submit_and_reset(const char* operation, std::string& error) noexcept {
        int submit_result = -1;
        try {
            submit_result = command != nullptr ? command->submit_and_wait() : -1;
        } catch (...) {
            // Treat an exception from the opaque ncnn submission boundary as
            // an ambiguous post-submit failure. The idle check below is the
            // only condition under which destroying its resources is safe.
            submit_result = -1;
        }

        if (submit_result != 0) {
            poisoned = true;

            // ncnn returns the same status for queue acquisition/submission
            // failures and for a failed infinite fence wait. The latter can
            // leave work in flight, so reset/destruction is allowed only after
            // a successful device-idle proof. If that proof fails, the owner
            // intentionally leaks this complete bundle rather than freeing a
            // command buffer or VkMat still referenced by the GPU.
            VkResult idle_result = VK_ERROR_DEVICE_LOST;
            if (device != nullptr && device->vkdevice() != VK_NULL_HANDLE
                && ncnn::vkDeviceWaitIdle != nullptr) {
                idle_result = ncnn::vkDeviceWaitIdle(device->vkdevice());
            }

            int reset_result = -1;
            if (idle_result == VK_SUCCESS) {
                try {
                    reset_result = command != nullptr ? command->reset() : -1;
                } catch (...) {
                    reset_result = -1;
                }
            } else {
                quarantine_on_destroy = true;
            }
            recording_active = false;

            char detail[512]{};
            if (quarantine_on_destroy) {
                std::snprintf(
                    detail,
                    sizeof(detail),
                    "%s failed with ncnn status %d; vkDeviceWaitIdle returned %d, so the persistent Vulkan resource bundle was quarantined until runtime teardown.",
                    operation,
                    submit_result,
                    static_cast<int>(idle_result));
            } else if (reset_result != 0) {
                std::snprintf(
                    detail,
                    sizeof(detail),
                    "%s failed with ncnn status %d; device idle was confirmed but command reset failed with ncnn status %d.",
                    operation,
                    submit_result,
                    reset_result);
            } else {
                std::snprintf(
                    detail,
                    sizeof(detail),
                    "%s failed with ncnn status %d; device idle was confirmed and the command was reset, but the context remains poisoned.",
                    operation,
                    submit_result);
            }
            set_poisoned_message_noexcept(detail);
            set_error_noexcept(error, detail);
#if defined(PLAINVIDEO_RIFE_GPU_TIMESTAMP_DIAGNOSTICS)
            timestamp_capture_pending = false;
            timestamp_available = false;
            hotspot_count = 0;
#endif
            return -1;
        }

#if defined(PLAINVIDEO_RIFE_GPU_TIMESTAMP_DIAGNOSTICS)
        timestamp_available = false;
        hotspot_count = 0;
        hotspot_layer_indices.fill(0);
        hotspot_duration_ns.fill(0);
        if (timestamp_capture_pending && command != nullptr
            && timestamp_results.size()
                >= timestamp_query_base + kGpuTimestampCount) {
            std::fill(timestamp_results.begin(), timestamp_results.end(), 0);
            const int query_result = command->get_query_pool_results(
                0,
                static_cast<std::uint32_t>(timestamp_results.size()),
                timestamp_results);
            const std::uint64_t start =
                timestamp_results[timestamp_query_base];
            const std::uint64_t preprocessed =
                timestamp_results[timestamp_query_base + 1];
            const std::uint64_t inferred =
                timestamp_results[timestamp_query_base + 2];
            const std::uint64_t postprocessed =
                timestamp_results[timestamp_query_base + 3];
            if (query_result == 0 && start != 0
                && start <= preprocessed && preprocessed <= inferred
                && inferred <= postprocessed) {
                upload_preprocess_ns = timestamp_duration_ns(
                    start, preprocessed, timestamp_period_ns);
                model_ns = timestamp_duration_ns(
                    preprocessed, inferred, timestamp_period_ns);
                postprocess_ns = timestamp_duration_ns(
                    inferred, postprocessed, timestamp_period_ns);
                compute_total_ns = timestamp_duration_ns(
                    start, postprocessed, timestamp_period_ns);
                timestamp_available = compute_total_ns != 0;
                std::vector<std::pair<std::uint64_t, std::uint32_t>>
                    layer_timings;
                const std::uint32_t layer_count =
                    timestamp_query_base / 2U;
                layer_timings.reserve(layer_count);
                for (std::uint32_t layer_index = 0;
                     layer_index < layer_count;
                     ++layer_index) {
                    const std::uint64_t layer_start =
                        timestamp_results[layer_index * 2U];
                    const std::uint64_t layer_end =
                        timestamp_results[layer_index * 2U + 1U];
                    if (layer_start == 0 || layer_end < layer_start) {
                        continue;
                    }
                    const std::uint64_t duration_ns = timestamp_duration_ns(
                        layer_start, layer_end, timestamp_period_ns);
                    if (duration_ns != 0) {
                        layer_timings.emplace_back(
                            duration_ns, layer_index);
                    }
                }
                std::sort(
                    layer_timings.begin(),
                    layer_timings.end(),
                    [](const auto& left, const auto& right) {
                        return left.first > right.first;
                    });
                hotspot_count = static_cast<std::uint32_t>(
                    std::min(layer_timings.size(),
                             hotspot_layer_indices.size()));
                for (std::uint32_t index = 0;
                     index < hotspot_count;
                     ++index) {
                    hotspot_duration_ns[index] =
                        layer_timings[index].first;
                    hotspot_layer_indices[index] =
                        layer_timings[index].second;
                }
            }
        }
        timestamp_capture_pending = false;
#endif

        int reset_result = -1;
        try {
            reset_result = command != nullptr ? command->reset() : -1;
        } catch (...) {
            reset_result = -1;
        }
        recording_active = false;
        if (reset_result != 0) {
            char detail[256]{};
            std::snprintf(
                detail,
                sizeof(detail),
                "Persistent RIFE Vulkan command reset failed with ncnn status %d after completed GPU work.",
                reset_result);
            set_poisoned_message_noexcept(detail);
            set_error_noexcept(error, detail);
            return -1;
        }
        return 0;
    }

    void begin_recording() noexcept {
        recording_active = true;
    }

    void abandon_recording_noexcept() noexcept {
        if (!recording_active) {
            return;
        }
        if (quarantine_on_destroy) {
            recording_active = false;
#if defined(PLAINVIDEO_RIFE_GPU_TIMESTAMP_DIAGNOSTICS)
            timestamp_capture_pending = false;
            timestamp_available = false;
            hotspot_count = 0;
#endif
            return;
        }

#if defined(PLAINVIDEO_RIFE_GPU_TIMESTAMP_DIAGNOSTICS)
        timestamp_capture_pending = false;
        timestamp_available = false;
        hotspot_count = 0;
#endif

        int reset_result = -1;
        try {
            reset_result = command != nullptr ? command->reset() : -1;
        } catch (...) {
            reset_result = -1;
        }
        recording_active = false;
        if (reset_result != 0) {
            set_poisoned_message_noexcept(
                "Persistent Vulkan command cleanup failed after an abandoned recording; the context is poisoned.");
        }
    }

    bool requires_quarantine() const noexcept {
        return quarantine_on_destroy;
    }

    void mark_poisoned(std::string reason) {
        poisoned = true;
        poison_reason = std::move(reason);
    }

    void set_poisoned_message_noexcept(const char* reason) noexcept {
        poisoned = true;
        try {
            poison_reason = reason != nullptr ? reason : "Persistent Vulkan context failure.";
        } catch (...) {
            poison_reason.clear();
        }
    }

    static void set_error_noexcept(std::string& error,
                                   const char* message) noexcept {
        try {
            error = message != nullptr ? message : "Persistent Vulkan context failure.";
        } catch (...) {
            error.clear();
        }
    }

    const ncnn::VulkanDevice* device = nullptr;
    ncnn::VkAllocator* blob_allocator = nullptr;
    ncnn::VkAllocator* staging_allocator = nullptr;
    ncnn::Option option;
    std::unique_ptr<ncnn::VkCompute> command;
    ncnn::VkMat upload0_staging;
    ncnn::VkMat upload1_staging;
    ncnn::VkMat input0_gpu;
    ncnn::VkMat input1_gpu;
    ncnn::VkMat input0_padded;
    ncnn::VkMat input1_padded;
    ncnn::VkMat timestep_gpu;
    ncnn::VkMat output_gpu;
    ncnn::VkMat download_staging;
    bool poisoned = false;
    bool recording_active = false;
    bool quarantine_on_destroy = false;
    std::string poison_reason;
#if defined(PLAINVIDEO_RIFE_GPU_TIMESTAMP_DIAGNOSTICS)
    std::uint32_t timestamp_query_base = 0;
    float timestamp_period_ns = 0.0F;
    std::vector<std::uint64_t> timestamp_results;
    bool timestamp_capture_pending = false;
    bool timestamp_available = false;
    std::uint64_t upload_preprocess_ns = 0;
    std::uint64_t model_ns = 0;
    std::uint64_t postprocess_ns = 0;
    std::uint64_t compute_total_ns = 0;
    std::uint32_t hotspot_count = 0;
    std::array<std::uint32_t, kCheckedRifeGpuHotspotCapacity>
        hotspot_layer_indices{};
    std::array<std::uint64_t, kCheckedRifeGpuHotspotCapacity>
        hotspot_duration_ns{};
#endif
};

PersistentRecordingGuard::PersistentRecordingGuard(
    PersistentVulkanResources& resources) noexcept
    : resources_(&resources) {
    resources_->begin_recording();
}

PersistentRecordingGuard::~PersistentRecordingGuard() noexcept {
    if (active_ && resources_ != nullptr) {
        resources_->abandon_recording_noexcept();
    }
}

bool valid_dimensions(int width, int height, std::ptrdiff_t stride) {
    return width > 0 && height > 0 && stride >= width
        && width <= std::numeric_limits<int>::max() - (kPadding - 1)
        && height <= std::numeric_limits<int>::max() - (kPadding - 1);
}

std::uint64_t elapsed_microseconds(std::chrono::steady_clock::time_point start,
                                   std::chrono::steady_clock::time_point end) {
    return static_cast<std::uint64_t>(
        std::chrono::duration_cast<std::chrono::microseconds>(end - start).count());
}

std::uint8_t pack_channel(float value) {
    const float clamped = std::clamp(value, 0.0F, 255.0F);
    return static_cast<std::uint8_t>(clamped + 0.5F);
}

} // namespace

struct CheckedRifeV4::Impl {
    Impl(int gpu_index,
         int inference_threads,
         bool enable_persistent_vulkan)
        : device(ncnn::get_gpu_device(gpu_index)),
          threads(inference_threads),
          persistent_vulkan_requested(enable_persistent_vulkan) {
    }

    ~Impl() {
        // Persistent command and buffer state must be gone before the model
        // pipelines and the process-wide Vulkan instance are torn down.
        persistent_vulkan.reset();
    }

    bool requires_quarantine() const noexcept {
        return quarantine_all_resources
            || (persistent_vulkan != nullptr
                && persistent_vulkan->requires_quarantine());
    }

    ncnn::VulkanDevice* device = nullptr;
    int threads = 1;
    ncnn::Net flownet;
    std::unique_ptr<ncnn::Pipeline> preprocessor;
    std::unique_ptr<ncnn::Pipeline> packed_bgra8_preprocessor;
    std::unique_ptr<ncnn::Pipeline> postprocessor;
    std::unique_ptr<ncnn::Pipeline> packed_bgra8_postprocessor;
    std::unique_ptr<ncnn::Pipeline> timestep;
    ncnn::Mat host_input0;
    ncnn::Mat host_input1;
    ncnn::Mat host_output;
    ncnn::Mat host_output_bgra8;
    bool persistent_vulkan_requested = false;
    bool quarantine_all_resources = false;
    std::unique_ptr<PersistentVulkanResources> persistent_vulkan;
    mutable std::mutex process_mutex;
    bool loaded = false;

    int run_gpu(const ncnn::Mat& input0,
                const ncnn::Mat& input1,
                ncnn::Mat& output,
                int width,
                int height,
                std::string& error) const;

    int run_gpu_persistent_vulkan(ncnn::Mat& output,
                                  std::string& error) const;
};

CheckedRifeV4::CheckedRifeV4(int gpu_index,
                             int inference_threads,
                             bool enable_persistent_vulkan)
    : impl_(std::make_unique<Impl>(gpu_index,
                                   inference_threads,
                                   enable_persistent_vulkan)) {
}

CheckedRifeV4::~CheckedRifeV4() {
    if (impl_ != nullptr && impl_->requires_quarantine()) {
        // A pending command can reference not only the persistent VkMat bundle
        // but also the pre/postprocess pipelines and flownet-owned weights and
        // workspaces. Quarantine the complete implementation graph. A rare
        // process-lifetime CPU/resource leak is safer than destroying any
        // object whose GPU use could not be proven complete.
        (void)impl_.release();
    }
}

int CheckedRifeV4::load(const std::wstring& model_directory,
                        std::string& error) {
    error.clear();
    if (impl_->device == nullptr) {
        return fail(error, "ncnn did not provide the selected Vulkan device.");
    }
    if (impl_->threads < 1) {
        return fail(error, "RIFE inference threads must be at least one.");
    }
    if (impl_->loaded) {
        return fail(error, "The RIFE core has already been loaded.");
    }

    // Allocate the fixed spike boundary before any measured process call.
    // Mat::create() reuses an existing allocation with the same shape, so a
    // failed load can be retried without adding first-call allocation noise.
    impl_->host_input0.create(kDirectWidth, kDirectHeight, kChannels,
                              sizeof(float), 1);
    impl_->host_input1.create(kDirectWidth, kDirectHeight, kChannels,
                              sizeof(float), 1);
    impl_->host_output.create(kDirectWidth, kDirectHeight, kChannels,
                              sizeof(float), 1);
    impl_->host_output_bgra8.create(kDirectWidth, kDirectHeight, 1,
                                    sizeof(std::uint32_t), 1);
    if (impl_->host_input0.empty() || impl_->host_input1.empty()
        || impl_->host_output.empty() || impl_->host_output_bgra8.empty()) {
        return fail(error, "ncnn could not allocate the persistent 1080p host frames.");
    }

    ncnn::Option option;
    option.num_threads = impl_->threads;
    option.use_vulkan_compute = true;
    option.use_fp16_packed = true;
    option.use_fp16_storage = true;
    // The pinned upstream RIFE runtime deliberately leaves FP16 arithmetic
    // disabled. Keep that exact behavior unless a local development probe
    // explicitly requests it, and still require hardware support.
    option.use_fp16_arithmetic = development_fp16_arithmetic_requested()
        && impl_->device->info.support_fp16_arithmetic();
    option.use_int8_storage = false;

    impl_->flownet.opt = option;
    impl_->flownet.set_vulkan_device(impl_->device);
#if defined(PLAINVIDEO_RIFE_FUSED_CONCAT_DIAGNOSTICS)
    if (development_fused_concat_requested()) {
        const int concat_register_result =
            impl_->flownet.register_custom_layer(
                "Concat",
                plainvideo_rife_concat7_layer_creator);
        if (concat_register_result != 0) {
            return fail(
                error,
                with_code(
                    "Fused diagnostic Concat registration",
                    concat_register_result));
        }
    }
#endif
    const int register_result = impl_->flownet.register_custom_layer(
        "rife.Warp", Warp_layer_creator);
    if (register_result != 0) {
        return fail(error, with_code("RIFE Warp layer registration", register_result));
    }

    const std::filesystem::path root(model_directory);
    if (load_net_file(impl_->flownet, root / L"flownet.param", true, error) != 0
        || load_net_file(impl_->flownet, root / L"flownet.bin", false, error) != 0) {
        return -1;
    }

    std::vector<ncnn::vk_specialization_type> frame_specializations(1);
    frame_specializations[0].i = 1;
    const std::vector<ncnn::vk_specialization_type> no_specializations;

    std::unique_ptr<ncnn::Pipeline> preprocessor;
    std::unique_ptr<ncnn::Pipeline> packed_bgra8_preprocessor;
    std::unique_ptr<ncnn::Pipeline> postprocessor;
    std::unique_ptr<ncnn::Pipeline> packed_bgra8_postprocessor;
    std::unique_ptr<ncnn::Pipeline> timestep;
    if (create_pipeline(impl_->device,
                        rife_preproc_comp_data,
                        sizeof(rife_preproc_comp_data),
                        option,
                        8,
                        8,
                        3,
                        frame_specializations,
                           preprocessor,
                           "RIFE preprocessing pipeline",
                           error) != 0
        || create_pipeline(impl_->device,
                           plainvideo_rife_preproc_bgra8_comp_data,
                           sizeof(plainvideo_rife_preproc_bgra8_comp_data) - 1,
                           option,
                           8,
                           8,
                           3,
                           no_specializations,
                           packed_bgra8_preprocessor,
                           "RIFE packed BGRA8 preprocessing pipeline",
                           error) != 0
        || create_pipeline(impl_->device,
                           rife_postproc_comp_data,
                           sizeof(rife_postproc_comp_data),
                           option,
                           8,
                           8,
                           3,
                           frame_specializations,
                           postprocessor,
                           "RIFE postprocessing pipeline",
                           error) != 0
        || create_pipeline(impl_->device,
                           plainvideo_rife_postproc_bgra8_comp_data,
                           sizeof(plainvideo_rife_postproc_bgra8_comp_data) - 1,
                           option,
                           8,
                           8,
                           1,
                           no_specializations,
                           packed_bgra8_postprocessor,
                           "RIFE packed BGRA8 postprocessing pipeline",
                           error) != 0
        || create_pipeline(impl_->device,
                           rife_v4_timestep_comp_data,
                           sizeof(rife_v4_timestep_comp_data),
                           option,
                           8,
                           8,
                           1,
                           no_specializations,
                           timestep,
                           "RIFE timestep pipeline",
                           error) != 0) {
        return -1;
    }

    impl_->preprocessor = std::move(preprocessor);
    impl_->packed_bgra8_preprocessor =
        std::move(packed_bgra8_preprocessor);
    impl_->postprocessor = std::move(postprocessor);
    impl_->packed_bgra8_postprocessor =
        std::move(packed_bgra8_postprocessor);
    impl_->timestep = std::move(timestep);

    if (impl_->persistent_vulkan_requested) {
        auto persistent_vulkan =
            std::make_unique<PersistentVulkanResources>(impl_->device);
        int initialize_result = -1;
        try {
            initialize_result = persistent_vulkan->initialize(
                option,
                impl_->timestep.get(),
                impl_->flownet.layers().size(),
                error);
        } catch (...) {
            if (persistent_vulkan->requires_quarantine()) {
                impl_->quarantine_all_resources = true;
                (void)persistent_vulkan.release();
            }
            throw;
        }
        if (initialize_result != 0) {
            if (persistent_vulkan->requires_quarantine()) {
                impl_->quarantine_all_resources = true;
                (void)persistent_vulkan.release();
            }
            return -1;
        }
        impl_->persistent_vulkan = std::move(persistent_vulkan);
    }

    impl_->loaded = true;
    return 0;
}

int CheckedRifeV4::Impl::run_gpu(const ncnn::Mat& input0,
                                 const ncnn::Mat& input1,
                                 ncnn::Mat& output,
                                 int width,
                                 int height,
                                 std::string& error) const {
    if (input0.empty() || input1.empty()
        || input0.w != width || input0.h != height || input0.c != kChannels
        || input1.w != width || input1.h != height || input1.c != kChannels
        || input0.elemsize != sizeof(float) || input1.elemsize != sizeof(float)
        || input0.elempack != 1 || input1.elempack != 1) {
        return fail(error, "RIFE received incompatible host input frames.");
    }

    VulkanAllocatorLease allocators(device);
    if (allocators.acquire(error) != 0) {
        return -1;
    }

    ncnn::Option option = flownet.opt;
    option.blob_vkallocator = allocators.blob();
    option.workspace_vkallocator = allocators.blob();
    option.staging_vkallocator = allocators.staging();

    const int padded_width = (width + kPadding - 1) / kPadding * kPadding;
    const int padded_height = (height + kPadding - 1) / kPadding * kPadding;
    const size_t storage_element_size = option.use_fp16_storage ? 2U : 4U;

    ncnn::VkCompute command(device);
    ncnn::VkMat input0_gpu;
    ncnn::VkMat input1_gpu;
    command.record_clone(input0, input0_gpu, option);
    command.record_clone(input1, input1_gpu, option);
    if (input0_gpu.empty() || input1_gpu.empty()) {
        return fail(error, "ncnn could not allocate or record Vulkan input uploads.");
    }

    ncnn::VkMat input0_padded;
    ncnn::VkMat input1_padded;
    input0_padded.create(padded_width, padded_height, kChannels,
                         storage_element_size, 1, allocators.blob());
    input1_padded.create(padded_width, padded_height, kChannels,
                         storage_element_size, 1, allocators.blob());
    if (input0_padded.empty() || input1_padded.empty()) {
        return fail(error, "ncnn could not allocate padded Vulkan input frames.");
    }

    {
        std::vector<ncnn::VkMat> bindings(2);
        bindings[0] = input0_gpu;
        bindings[1] = input0_padded;
        std::vector<ncnn::vk_constant_type> constants(6);
        constants[0].i = input0_gpu.w;
        constants[1].i = input0_gpu.h;
        constants[2].i = static_cast<int>(input0_gpu.cstep);
        constants[3].i = input0_padded.w;
        constants[4].i = input0_padded.h;
        constants[5].i = static_cast<int>(input0_padded.cstep);
        command.record_pipeline(preprocessor.get(), bindings, constants,
                                input0_padded);
    }
    {
        std::vector<ncnn::VkMat> bindings(2);
        bindings[0] = input1_gpu;
        bindings[1] = input1_padded;
        std::vector<ncnn::vk_constant_type> constants(6);
        constants[0].i = input1_gpu.w;
        constants[1].i = input1_gpu.h;
        constants[2].i = static_cast<int>(input1_gpu.cstep);
        constants[3].i = input1_padded.w;
        constants[4].i = input1_padded.h;
        constants[5].i = static_cast<int>(input1_padded.cstep);
        command.record_pipeline(preprocessor.get(), bindings, constants,
                                input1_padded);
    }

    ncnn::VkMat timestep_gpu;
    timestep_gpu.create(padded_width, padded_height, 1,
                        storage_element_size, 1, allocators.blob());
    if (timestep_gpu.empty()) {
        return fail(error, "ncnn could not allocate the Vulkan timestep frame.");
    }
    {
        std::vector<ncnn::VkMat> bindings(1);
        bindings[0] = timestep_gpu;
        std::vector<ncnn::vk_constant_type> constants(4);
        constants[0].i = timestep_gpu.w;
        constants[1].i = timestep_gpu.h;
        constants[2].i = static_cast<int>(timestep_gpu.cstep);
        constants[3].f = kTimestep;
        command.record_pipeline(timestep.get(), bindings, constants,
                                timestep_gpu);
    }

    ncnn::VkMat output_padded;
    {
        ncnn::Extractor extractor = flownet.create_extractor();
        extractor.set_blob_vkallocator(allocators.blob());
        extractor.set_workspace_vkallocator(allocators.blob());
        extractor.set_staging_vkallocator(allocators.staging());

        int result = extractor.input("in0", input0_padded);
        if (result != 0) {
            return fail(error, with_code("RIFE input in0", result));
        }
        result = extractor.input("in1", input1_padded);
        if (result != 0) {
            return fail(error, with_code("RIFE input in1", result));
        }
        result = extractor.input("in2", timestep_gpu);
        if (result != 0) {
            return fail(error, with_code("RIFE input in2", result));
        }
        result = extractor.extract("out0", output_padded, command);
        if (result != 0) {
            return fail(error, with_code("RIFE output out0 extraction", result));
        }
        if (output_padded.empty()) {
            return fail(error, "RIFE output extraction returned an empty Vulkan frame.");
        }
    }

    ncnn::VkMat output_gpu;
    output_gpu.create(width, height, kChannels, sizeof(float), 1,
                      allocators.blob());
    if (output_gpu.empty()) {
        return fail(error, "ncnn could not allocate the Vulkan output frame.");
    }
    {
        std::vector<ncnn::VkMat> bindings(2);
        bindings[0] = output_padded;
        bindings[1] = output_gpu;
        std::vector<ncnn::vk_constant_type> constants(6);
        constants[0].i = output_padded.w;
        constants[1].i = output_padded.h;
        constants[2].i = static_cast<int>(output_padded.cstep);
        constants[3].i = output_gpu.w;
        constants[4].i = output_gpu.h;
        constants[5].i = static_cast<int>(output_gpu.cstep);
        command.record_pipeline(postprocessor.get(), bindings, constants,
                                output_gpu);
    }

    command.record_clone(output_gpu, output, option);
    if (output.empty()) {
        return fail(error, "ncnn could not allocate or record the host output download.");
    }

    const int submit_result = command.submit_and_wait();
    if (submit_result != 0) {
        return fail(error, with_code("RIFE Vulkan submission", submit_result));
    }
    if (output.empty() || output.w != width || output.h != height
        || output.c != kChannels || output.elemsize != sizeof(float)
        || output.elempack != 1) {
        return fail(error, "RIFE returned an incompatible host output frame.");
    }

    return 0;
}

int CheckedRifeV4::Impl::run_gpu_persistent_vulkan(
    ncnn::Mat& output,
    std::string& error) const {
    PersistentVulkanResources* resources = persistent_vulkan.get();
    if (resources == nullptr) {
        return fail(error,
                    "The persistent staged Vulkan path was not enabled at load time.");
    }
    if (resources->poisoned) {
        return fail(error,
                    "The persistent staged Vulkan context is unavailable after an "
                    "earlier command failure: "
                        + resources->poison_reason);
    }
    if (resources->command == nullptr) {
        resources->mark_poisoned(
            "The persistent staged Vulkan command context is unavailable.");
        return fail(error, resources->poison_reason);
    }

    ncnn::VkCompute& command = *resources->command;
    const ncnn::Option& option = resources->option;
    PersistentRecordingGuard recording_guard(*resources);

#if defined(PLAINVIDEO_RIFE_FUSED_CONCAT_DIAGNOSTICS)
    plainvideo_rife_concat7_reset_thread_stats();
#endif

#if defined(PLAINVIDEO_RIFE_GPU_TIMESTAMP_DIAGNOSTICS)
    resources->timestamp_available = false;
    resources->timestamp_capture_pending = true;
    resources->hotspot_count = 0;
    command.record_write_timestamp(resources->timestamp_query_base);
#endif

    command.record_clone(resources->upload0_staging,
                         resources->input0_gpu,
                         option);
    command.record_clone(resources->upload1_staging,
                         resources->input1_gpu,
                         option);
    if (resources->input0_gpu.empty() || resources->input1_gpu.empty()) {
        return resources->abort_recording(
            "ncnn could not record the persistent Vulkan input uploads.", error);
    }

    {
        std::vector<ncnn::VkMat> bindings(2);
        bindings[0] = resources->input0_gpu;
        bindings[1] = resources->input0_padded;
        std::vector<ncnn::vk_constant_type> constants(6);
        constants[0].i = resources->input0_gpu.w;
        constants[1].i = resources->input0_gpu.h;
        constants[2].i = static_cast<int>(resources->input0_gpu.cstep);
        constants[3].i = resources->input0_padded.w;
        constants[4].i = resources->input0_padded.h;
        constants[5].i = static_cast<int>(resources->input0_padded.cstep);
        command.record_pipeline(packed_bgra8_preprocessor.get(), bindings,
                                constants,
                                resources->input0_padded);
    }
    {
        std::vector<ncnn::VkMat> bindings(2);
        bindings[0] = resources->input1_gpu;
        bindings[1] = resources->input1_padded;
        std::vector<ncnn::vk_constant_type> constants(6);
        constants[0].i = resources->input1_gpu.w;
        constants[1].i = resources->input1_gpu.h;
        constants[2].i = static_cast<int>(resources->input1_gpu.cstep);
        constants[3].i = resources->input1_padded.w;
        constants[4].i = resources->input1_padded.h;
        constants[5].i = static_cast<int>(resources->input1_padded.cstep);
        command.record_pipeline(packed_bgra8_preprocessor.get(), bindings,
                                constants,
                                resources->input1_padded);
    }

#if defined(PLAINVIDEO_RIFE_GPU_TIMESTAMP_DIAGNOSTICS)
    command.record_write_timestamp(resources->timestamp_query_base + 1);
#endif

    ncnn::VkMat output_padded;
    {
        // Extractors cache produced blobs, so a fresh instance is required for
        // every frame pair even though its allocators remain persistent.
        ncnn::Extractor extractor = flownet.create_extractor();
        extractor.set_blob_vkallocator(resources->blob_allocator);
        extractor.set_workspace_vkallocator(resources->blob_allocator);
        extractor.set_staging_vkallocator(resources->staging_allocator);

        int result = extractor.input("in0", resources->input0_padded);
        if (result != 0) {
            return resources->abort_recording(
                with_code("Persistent RIFE input in0", result), error);
        }
        result = extractor.input("in1", resources->input1_padded);
        if (result != 0) {
            return resources->abort_recording(
                with_code("Persistent RIFE input in1", result), error);
        }
        result = extractor.input("in2", resources->timestep_gpu);
        if (result != 0) {
            return resources->abort_recording(
                with_code("Persistent RIFE input in2", result), error);
        }
        result = extractor.extract("out0", output_padded, command);
        if (result != 0) {
            return resources->abort_recording(
                with_code("Persistent RIFE output out0 extraction", result),
                error);
        }
        if (output_padded.empty()) {
            return resources->abort_recording(
                "Persistent RIFE output extraction returned an empty Vulkan frame.",
                error);
        }
    }

#if defined(PLAINVIDEO_RIFE_GPU_TIMESTAMP_DIAGNOSTICS)
    command.record_write_timestamp(resources->timestamp_query_base + 2);
#endif

    {
        std::vector<ncnn::VkMat> bindings(2);
        bindings[0] = output_padded;
        bindings[1] = resources->output_gpu;
        std::vector<ncnn::vk_constant_type> constants(6);
        constants[0].i = output_padded.w;
        constants[1].i = output_padded.h;
        constants[2].i = static_cast<int>(output_padded.cstep);
        constants[3].i = resources->output_gpu.w;
        constants[4].i = resources->output_gpu.h;
        constants[5].i = static_cast<int>(resources->output_gpu.cstep);
        command.record_pipeline(packed_bgra8_postprocessor.get(), bindings,
                                constants, resources->output_gpu);
    }


#if defined(PLAINVIDEO_RIFE_GPU_TIMESTAMP_DIAGNOSTICS)
    command.record_write_timestamp(resources->timestamp_query_base + 3);
#endif

    ncnn::Option staging_option = option;
    staging_option.blob_vkallocator = resources->staging_allocator;
    command.record_clone(resources->output_gpu,
                         resources->download_staging,
                         staging_option);
    if (resources->download_staging.empty()) {
        return resources->abort_recording(
            "ncnn could not record the persistent Vulkan output download.", error);
    }

    // This second clone records ncnn's transfer-to-host barrier and performs
    // the coherent staging invalidate plus copy after fence completion. Reading
    // mapped download memory directly would skip that public synchronization
    // boundary.
    command.record_clone(resources->download_staging, output, option);
    if (output.empty()) {
        return resources->abort_recording(
            "ncnn could not record the persistent host output copy.", error);
    }

    const int submit_result = resources->submit_and_reset(
        "Persistent RIFE Vulkan submission", error);
    recording_guard.dismiss();
    if (submit_result != 0) {
        return -1;
    }
    if (output.w != kDirectWidth || output.h != kDirectHeight
        || output.c != 1 || output.elemsize != sizeof(std::uint32_t)
        || output.elempack != 1) {
        return fail(error,
                    "Persistent RIFE returned an incompatible packed BGRA8 host frame.");
    }

    return 0;
}

int CheckedRifeV4::process(const float* src0_r,
                           const float* src0_g,
                           const float* src0_b,
                           const float* src1_r,
                           const float* src1_g,
                           const float* src1_b,
                           float* dst_r,
                           float* dst_g,
                           float* dst_b,
                           int width,
                           int height,
                           std::ptrdiff_t stride,
                           float timestep,
                           std::string& error) const {
    error.clear();
    if (!impl_->loaded || impl_->device == nullptr
        || impl_->preprocessor == nullptr
        || impl_->packed_bgra8_preprocessor == nullptr
        || impl_->postprocessor == nullptr
        || impl_->packed_bgra8_postprocessor == nullptr
        || impl_->timestep == nullptr) {
        return fail(error, "The checked RIFE core is not loaded.");
    }
    if (src0_r == nullptr || src0_g == nullptr || src0_b == nullptr
        || src1_r == nullptr || src1_g == nullptr || src1_b == nullptr
        || dst_r == nullptr || dst_g == nullptr || dst_b == nullptr) {
        return fail(error, "The checked RIFE core requires two RGB inputs and one RGB output.");
    }
    if (!valid_dimensions(width, height, stride)) {
        return fail(error, "The checked RIFE core received invalid frame dimensions or stride.");
    }
    if (!std::isfinite(timestep) || std::fabs(timestep - kTimestep) > 0.0001F) {
        return fail(error, "The checked RIFE core supports only timestep 0.5.");
    }

    ncnn::Mat input0;
    ncnn::Mat input1;
    input0.create(width, height, kChannels, sizeof(float), 1);
    input1.create(width, height, kChannels, sizeof(float), 1);
    if (input0.empty() || input1.empty()) {
        return fail(error, "ncnn could not allocate host input frames.");
    }

    float* input0_r = input0.channel(0);
    float* input0_g = input0.channel(1);
    float* input0_b = input0.channel(2);
    float* input1_r = input1.channel(0);
    float* input1_g = input1.channel(1);
    float* input1_b = input1.channel(2);
    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
            const std::ptrdiff_t source_index = stride * y + x;
            const size_t target_index = static_cast<size_t>(width) * y + x;
            input0_r[target_index] = src0_r[source_index] * 255.0F;
            input0_g[target_index] = src0_g[source_index] * 255.0F;
            input0_b[target_index] = src0_b[source_index] * 255.0F;
            input1_r[target_index] = src1_r[source_index] * 255.0F;
            input1_g[target_index] = src1_g[source_index] * 255.0F;
            input1_b[target_index] = src1_b[source_index] * 255.0F;
        }
    }

    ncnn::Mat output;
    {
        std::scoped_lock lock(impl_->process_mutex);
        if (impl_->run_gpu(input0, input1, output, width, height, error) != 0) {
            return -1;
        }
    }

    const float* output_r = output.channel(0);
    const float* output_g = output.channel(1);
    const float* output_b = output.channel(2);
    constexpr float scale = 1.0F / 255.0F;
    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
            const size_t source_index = static_cast<size_t>(width) * y + x;
            const std::ptrdiff_t target_index = stride * y + x;
            dst_r[target_index] = output_r[source_index] * scale;
            dst_g[target_index] = output_g[source_index] * scale;
            dst_b[target_index] = output_b[source_index] * scale;
        }
    }

    return 0;
}

int CheckedRifeV4::process_bgra8(const std::uint8_t* src0_bgra,
                                 std::ptrdiff_t src0_stride_bytes,
                                 const std::uint8_t* src1_bgra,
                                 std::ptrdiff_t src1_stride_bytes,
                                 std::uint8_t* dst_bgra,
                                 std::ptrdiff_t dst_stride_bytes,
                                 float timestep,
                                 CheckedRifeV4Timings& timings,
                                 std::string& error) const {
    error.clear();
    timings = {};
    if (!impl_->loaded || impl_->device == nullptr
        || impl_->preprocessor == nullptr || impl_->postprocessor == nullptr
        || impl_->timestep == nullptr) {
        return fail(error, "The checked RIFE core is not loaded.");
    }
    if (src0_bgra == nullptr || src1_bgra == nullptr || dst_bgra == nullptr) {
        return fail(error, "The direct RIFE boundary requires two BGRA8 inputs and one output.");
    }
    constexpr std::ptrdiff_t minimum_stride = kDirectWidth * kBgraChannels;
    if (src0_stride_bytes < minimum_stride
        || src1_stride_bytes < minimum_stride
        || dst_stride_bytes < minimum_stride) {
        return fail(error, "The direct RIFE boundary received an invalid BGRA8 stride.");
    }
    if (!std::isfinite(timestep) || std::fabs(timestep - kTimestep) > 0.0001F) {
        return fail(error, "The checked RIFE core supports only timestep 0.5.");
    }
    if (impl_->host_input0.empty() || impl_->host_input1.empty()
        || impl_->host_output.empty()) {
        return fail(error, "The persistent 1080p host frames are unavailable.");
    }

    std::scoped_lock lock(impl_->process_mutex);
    const auto core_start = std::chrono::steady_clock::now();
    const auto input_start = core_start;

    float* input0_r = impl_->host_input0.channel(0);
    float* input0_g = impl_->host_input0.channel(1);
    float* input0_b = impl_->host_input0.channel(2);
    float* input1_r = impl_->host_input1.channel(0);
    float* input1_g = impl_->host_input1.channel(1);
    float* input1_b = impl_->host_input1.channel(2);
    for (int y = 0; y < kDirectHeight; ++y) {
        const std::uint8_t* row0 = src0_bgra + src0_stride_bytes * y;
        const std::uint8_t* row1 = src1_bgra + src1_stride_bytes * y;
        const size_t row_offset = static_cast<size_t>(kDirectWidth) * y;
        for (int x = 0; x < kDirectWidth; ++x) {
            const size_t bgra_offset = static_cast<size_t>(x) * kBgraChannels;
            const size_t target = row_offset + x;
            input0_b[target] = static_cast<float>(row0[bgra_offset]);
            input0_g[target] = static_cast<float>(row0[bgra_offset + 1]);
            input0_r[target] = static_cast<float>(row0[bgra_offset + 2]);
            input1_b[target] = static_cast<float>(row1[bgra_offset]);
            input1_g[target] = static_cast<float>(row1[bgra_offset + 1]);
            input1_r[target] = static_cast<float>(row1[bgra_offset + 2]);
        }
    }
    const auto input_end = std::chrono::steady_clock::now();
    timings.host_input_prepare_us = elapsed_microseconds(input_start, input_end);

    const auto gpu_start = input_end;
    const int gpu_result = impl_->run_gpu(impl_->host_input0,
                                          impl_->host_input1,
                                          impl_->host_output,
                                          kDirectWidth,
                                          kDirectHeight,
                                          error);
    const auto gpu_end = std::chrono::steady_clock::now();
    timings.gpu_path_us = elapsed_microseconds(gpu_start, gpu_end);
    if (gpu_result != 0) {
        timings.core_path_us = elapsed_microseconds(core_start, gpu_end);
        return -1;
    }

    const auto output_start = gpu_end;
    const float* output_r = impl_->host_output.channel(0);
    const float* output_g = impl_->host_output.channel(1);
    const float* output_b = impl_->host_output.channel(2);
    for (int y = 0; y < kDirectHeight; ++y) {
        std::uint8_t* row = dst_bgra + dst_stride_bytes * y;
        const size_t row_offset = static_cast<size_t>(kDirectWidth) * y;
        for (int x = 0; x < kDirectWidth; ++x) {
            const size_t source = row_offset + x;
            if (!std::isfinite(output_r[source])
                || !std::isfinite(output_g[source])
                || !std::isfinite(output_b[source])) {
                const auto failure_time = std::chrono::steady_clock::now();
                timings.host_output_pack_us =
                    elapsed_microseconds(output_start, failure_time);
                timings.core_path_us = elapsed_microseconds(core_start, failure_time);
                return fail(error, "RIFE produced a non-finite host output sample.");
            }
            const size_t bgra_offset = static_cast<size_t>(x) * kBgraChannels;
            row[bgra_offset] = pack_channel(output_b[source]);
            row[bgra_offset + 1] = pack_channel(output_g[source]);
            row[bgra_offset + 2] = pack_channel(output_r[source]);
            row[bgra_offset + 3] = 255;
        }
    }
    const auto output_end = std::chrono::steady_clock::now();
    timings.host_output_pack_us = elapsed_microseconds(output_start, output_end);
    timings.core_path_us = elapsed_microseconds(core_start, output_end);
    return 0;
}

int CheckedRifeV4::process_bgra8_persistent_vulkan(
    const std::uint8_t* src0_bgra,
    std::ptrdiff_t src0_stride_bytes,
    const std::uint8_t* src1_bgra,
    std::ptrdiff_t src1_stride_bytes,
    std::uint8_t* dst_bgra,
    std::ptrdiff_t dst_stride_bytes,
    float timestep,
    CheckedRifeV4Timings& timings,
    std::string& error) const {
    error.clear();
    timings = {};
    if (!impl_->loaded || impl_->device == nullptr
        || impl_->preprocessor == nullptr || impl_->postprocessor == nullptr
        || impl_->timestep == nullptr) {
        return fail(error, "The checked RIFE core is not loaded.");
    }
    if (src0_bgra == nullptr || src1_bgra == nullptr || dst_bgra == nullptr) {
        return fail(error,
                    "The persistent staged RIFE boundary requires two BGRA8 "
                    "inputs and one output.");
    }
    constexpr std::ptrdiff_t minimum_stride = kDirectWidth * kBgraChannels;
    if (src0_stride_bytes < minimum_stride
        || src1_stride_bytes < minimum_stride
        || dst_stride_bytes < minimum_stride) {
        return fail(error,
                    "The persistent staged RIFE boundary received an invalid "
                    "BGRA8 stride.");
    }
    if (!std::isfinite(timestep) || std::fabs(timestep - kTimestep) > 0.0001F) {
        return fail(error, "The checked RIFE core supports only timestep 0.5.");
    }
    if (impl_->persistent_vulkan == nullptr) {
        return fail(error,
                    "The persistent staged Vulkan path was not enabled at load time.");
    }
    if (impl_->host_output_bgra8.empty()) {
        return fail(error, "The persistent packed 1080p host output frame is unavailable.");
    }

    std::scoped_lock lock(impl_->process_mutex);
    PersistentVulkanResources& resources = *impl_->persistent_vulkan;
    const auto core_start = std::chrono::steady_clock::now();
    const auto input_start = core_start;

    if (resources.poisoned) {
        return fail(error,
                    "The persistent staged Vulkan context is unavailable after "
                    "an earlier command failure: "
                        + resources.poison_reason);
    }

    ncnn::Mat input0_mapped = resources.upload0_staging.mapped();
    ncnn::Mat input1_mapped = resources.upload1_staging.mapped();
    if (input0_mapped.empty() || input1_mapped.empty()) {
        resources.mark_poisoned(
            "The persistent Vulkan upload staging frames are no longer mapped.");
        return fail(error, resources.poison_reason);
    }

    auto* input0 = reinterpret_cast<std::uint8_t*>(input0_mapped.data);
    auto* input1 = reinterpret_cast<std::uint8_t*>(input1_mapped.data);
    constexpr size_t packed_row_bytes =
        static_cast<size_t>(kDirectWidth) * kBgraChannels;
    for (int y = 0; y < kDirectHeight; ++y) {
        const std::uint8_t* row0 = src0_bgra + src0_stride_bytes * y;
        const std::uint8_t* row1 = src1_bgra + src1_stride_bytes * y;
        const size_t target = packed_row_bytes * static_cast<size_t>(y);
        std::memcpy(input0 + target, row0, packed_row_bytes);
        std::memcpy(input1 + target, row1, packed_row_bytes);
    }

    const int flush0 = resources.staging_allocator->flush(
        resources.upload0_staging.data);
    const int flush1 = resources.staging_allocator->flush(
        resources.upload1_staging.data);
    const auto input_end = std::chrono::steady_clock::now();
    timings.host_input_prepare_us = elapsed_microseconds(input_start, input_end);
    if (flush0 != 0 || flush1 != 0) {
        resources.mark_poisoned(
            "ncnn could not flush the persistent Vulkan upload staging frames.");
        timings.core_path_us = elapsed_microseconds(core_start, input_end);
        return fail(error, resources.poison_reason);
    }

    // The previous GPU work has completed at a fence before these mapped
    // writes. Publish their new state so ncnn records host-to-transfer barriers.
    resources.upload0_staging.data->access_flags = VK_ACCESS_HOST_WRITE_BIT;
    resources.upload0_staging.data->stage_flags = VK_PIPELINE_STAGE_HOST_BIT;
    resources.upload1_staging.data->access_flags = VK_ACCESS_HOST_WRITE_BIT;
    resources.upload1_staging.data->stage_flags = VK_PIPELINE_STAGE_HOST_BIT;

    const auto gpu_start = input_end;
    const int gpu_result = impl_->run_gpu_persistent_vulkan(
        impl_->host_output_bgra8, error);
    const auto gpu_end = std::chrono::steady_clock::now();
    // This is host wall time for command recording, upload, inference,
    // download, fence wait, host copy, and command reset; it is not kernel time.
    timings.gpu_path_us = elapsed_microseconds(gpu_start, gpu_end);
#if defined(PLAINVIDEO_RIFE_GPU_TIMESTAMP_DIAGNOSTICS)
    timings.gpu_timestamps_available = resources.timestamp_available;
    timings.gpu_upload_preprocess_ns = resources.upload_preprocess_ns;
    timings.gpu_model_ns = resources.model_ns;
    timings.gpu_postprocess_ns = resources.postprocess_ns;
    timings.gpu_compute_total_ns = resources.compute_total_ns;
    const auto& layers = impl_->flownet.layers();
    timings.gpu_hotspot_count = static_cast<std::uint32_t>(
        std::min<std::size_t>(
            resources.hotspot_count,
            kCheckedRifeGpuHotspotCapacity));
    for (std::uint32_t index = 0;
         index < timings.gpu_hotspot_count;
         ++index) {
        const std::uint32_t layer_index =
            resources.hotspot_layer_indices[index];
        if (layer_index >= layers.size() || layers[layer_index] == nullptr) {
            timings.gpu_hotspot_labels[index] =
                "layer-" + std::to_string(layer_index);
        } else {
            timings.gpu_hotspot_labels[index] =
                layers[layer_index]->type + ":" + layers[layer_index]->name;
        }
        timings.gpu_hotspot_duration_ns[index] =
            resources.hotspot_duration_ns[index];
    }
#endif
#if defined(PLAINVIDEO_RIFE_FUSED_CONCAT_DIAGNOSTICS)
    timings.gpu_fused_concat_calls =
        plainvideo_rife_concat7_thread_fused_calls();
    timings.gpu_fused_concat_fallback_calls =
        plainvideo_rife_concat7_thread_fallback_calls();
#endif
    if (gpu_result != 0) {
        timings.core_path_us = elapsed_microseconds(core_start, gpu_end);
        return -1;
    }

    const auto output_start = gpu_end;
    const auto* output = reinterpret_cast<const std::uint32_t*>(
        impl_->host_output_bgra8.data);
    constexpr size_t row_bytes =
        static_cast<size_t>(kDirectWidth) * kBgraChannels;
    constexpr size_t pixel_count =
        static_cast<size_t>(kDirectWidth) * kDirectHeight;
    const auto invalid_output = std::find_if(
        output,
        output + pixel_count,
        [](std::uint32_t pixel) {
            return (pixel & 0xff000000U) != 0xff000000U;
        });
    if (invalid_output != output + pixel_count) {
        const auto failure_time = std::chrono::steady_clock::now();
        timings.host_output_pack_us =
            elapsed_microseconds(output_start, failure_time);
        timings.core_path_us = elapsed_microseconds(core_start, failure_time);
        return fail(error, "RIFE produced a non-finite GPU output sample.");
    }

    if (dst_stride_bytes == static_cast<std::ptrdiff_t>(row_bytes)) {
        std::memcpy(dst_bgra, output, row_bytes * kDirectHeight);
    } else {
        const auto* output_bytes = reinterpret_cast<const std::uint8_t*>(output);
        for (int y = 0; y < kDirectHeight; ++y) {
            std::memcpy(dst_bgra + dst_stride_bytes * y,
                        output_bytes + row_bytes * y,
                        row_bytes);
        }
    }
    const auto output_end = std::chrono::steady_clock::now();
    timings.host_output_pack_us = elapsed_microseconds(output_start, output_end);
    timings.core_path_us = elapsed_microseconds(core_start, output_end);
    return 0;
}
