#include "plainvideo_rife.h"

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

struct Options {
    std::string model_directory;
    std::string json_path;
    std::string variant = "persistent-host";
    uint32_t width = 1920;
    uint32_t height = 1080;
    uint32_t source_fps = 30;
    uint32_t warmup = 10;
    uint32_t iterations = 60;
    int32_t gpu_index = -1;
};

uint32_t parse_unsigned(const std::string& value, const char* name) {
    size_t consumed = 0;
    const unsigned long parsed = std::stoul(value, &consumed, 10);
    if (consumed != value.size() || parsed > UINT32_MAX) {
        throw std::runtime_error(std::string("Invalid ") + name + ": " + value);
    }
    return static_cast<uint32_t>(parsed);
}

int32_t parse_signed(const std::string& value, const char* name) {
    size_t consumed = 0;
    const long parsed = std::stol(value, &consumed, 10);
    if (consumed != value.size() || parsed < INT32_MIN || parsed > INT32_MAX) {
        throw std::runtime_error(std::string("Invalid ") + name + ": " + value);
    }
    return static_cast<int32_t>(parsed);
}

Options parse_options(int argc, char** argv) {
    Options options;
    for (int index = 1; index < argc; ++index) {
        const std::string argument = argv[index];
        if (argument == "--help") {
            std::cout
                << "plainvideo_rife_bench --model <directory> [options]\n"
                << "  --fps <24|30>       Source cadence (default: 30)\n"
                << "  --warmup <count>    Unmeasured inference count (default: 10)\n"
                << "  --iterations <n>    Measured inference count (default: 60)\n"
                << "  --gpu <index|-1>    Vulkan GPU index (default: -1)\n"
                << "  --variant <name>    legacy, persistent-host, or persistent-vulkan (default: persistent-host)\n"
                << "  --json <path>       Also write the JSON result to this path\n";
            std::exit(0);
        }
        if (index + 1 >= argc) {
            throw std::runtime_error("Missing value after " + argument);
        }
        const std::string value = argv[++index];
        if (argument == "--model") {
            options.model_directory = value;
        } else if (argument == "--json") {
            options.json_path = value;
        } else if (argument == "--fps") {
            options.source_fps = parse_unsigned(value, "fps");
        } else if (argument == "--warmup") {
            options.warmup = parse_unsigned(value, "warmup");
        } else if (argument == "--iterations") {
            options.iterations = parse_unsigned(value, "iterations");
        } else if (argument == "--gpu") {
            options.gpu_index = parse_signed(value, "gpu");
        } else if (argument == "--variant") {
            options.variant = value;
        } else {
            throw std::runtime_error("Unknown option: " + argument);
        }
    }

    if (options.model_directory.empty()) {
        throw std::runtime_error("--model is required.");
    }
    if (options.width != 1920 || options.height != 1080) {
        throw std::runtime_error("Slice 3A supports only 1920x1080.");
    }
    if (options.source_fps != 24 && options.source_fps != 30) {
        throw std::runtime_error("--fps must be 24 or 30.");
    }
    if (options.iterations < 2) {
        throw std::runtime_error("--iterations must be at least 2.");
    }
    if (options.variant != "legacy" && options.variant != "persistent-host"
        && options.variant != "persistent-vulkan") {
        throw std::runtime_error(
            "--variant must be legacy, persistent-host, or persistent-vulkan.");
    }
    return options;
}

std::string escape_json(const std::string& value) {
    std::ostringstream escaped;
    for (const unsigned char character : value) {
        switch (character) {
        case '\\': escaped << "\\\\"; break;
        case '"': escaped << "\\\""; break;
        case '\n': escaped << "\\n"; break;
        case '\r': escaped << "\\r"; break;
        case '\t': escaped << "\\t"; break;
        default:
            if (character < 0x20) {
                escaped << "\\u" << std::hex << std::setw(4) << std::setfill('0')
                        << static_cast<int>(character) << std::dec;
            } else {
                escaped << character;
            }
        }
    }
    return escaped.str();
}

void make_frame(std::vector<uint8_t>& frame, uint32_t width, uint32_t height,
                uint32_t phase) {
    for (uint32_t y = 0; y < height; ++y) {
        for (uint32_t x = 0; x < width; ++x) {
            const size_t offset = (static_cast<size_t>(y) * width + x) * 4;
            const bool moving_tile = x >= 240 + phase && x < 720 + phase
                && y >= 270 && y < 810;
            frame[offset] = static_cast<uint8_t>((x / 3 + phase * 2) % 256);
            frame[offset + 1] = static_cast<uint8_t>((y / 2 + phase) % 256);
            frame[offset + 2] = moving_tile ? 238 : static_cast<uint8_t>((x + y) % 192);
            frame[offset + 3] = 255;
        }
    }
}

double percentile(std::vector<uint64_t> values, double fraction) {
    std::sort(values.begin(), values.end());
    const size_t rank = static_cast<size_t>(std::ceil(fraction * values.size()));
    return static_cast<double>(values[std::max<size_t>(1, rank) - 1]) / 1000.0;
}

double average_ms(const std::vector<uint64_t>& values) {
    long double total = 0;
    for (const uint64_t value : values) {
        total += value;
    }
    return static_cast<double>(total / values.size() / 1000.0L);
}

void append_samples(std::ostringstream& output, const std::vector<uint64_t>& values) {
    output << '[';
    for (size_t index = 0; index < values.size(); ++index) {
        if (index > 0) {
            output << ',';
        }
        output << values[index];
    }
    output << ']';
}

void append_timing_summary(std::ostringstream& output,
                           const std::vector<uint64_t>& values) {
    output << "{\"mean\": " << average_ms(values)
           << ", \"p50\": " << percentile(values, 0.50)
           << ", \"p90\": " << percentile(values, 0.90)
           << ", \"p95\": " << percentile(values, 0.95)
           << ", \"p99\": " << percentile(values, 0.99)
           << ", \"max\": " << percentile(values, 1.0) << '}';
}

// FNV-1a 64-bit is deliberately used as a small, stable evidence digest. The
// hash covers every byte of the generated BGRA8 output in row-major order.
uint64_t fnv1a64(const uint8_t* data, size_t size) {
    constexpr uint64_t offset_basis = 14695981039346656037ULL;
    constexpr uint64_t prime = 1099511628211ULL;
    uint64_t digest = offset_basis;
    for (size_t index = 0; index < size; ++index) {
        digest ^= static_cast<uint64_t>(data[index]);
        digest *= prime;
    }
    return digest;
}

std::string format_digest(uint64_t digest) {
    std::ostringstream formatted;
    formatted << std::hex << std::nouppercase << std::setw(16)
              << std::setfill('0') << digest;
    return formatted.str();
}

bool output_matches_fallback(const std::vector<uint8_t>& frame0,
                             const uint8_t* output) {
    return output != nullptr
        && std::memcmp(frame0.data(), output, frame0.size()) == 0;
}

} // namespace

int main(int argc, char** argv) {
    try {
        const Options options = parse_options(argc, argv);
        const bool persistent_host_variant = options.variant == "persistent-host";
        const bool persistent_vulkan_variant = options.variant == "persistent-vulkan";
        const bool candidate_variant = persistent_host_variant
            || persistent_vulkan_variant;
        const char* const variant_id = persistent_vulkan_variant
            ? "persistent-vulkan-staged"
            : (persistent_host_variant
                ? "persistent-host-direct-bgra"
                : "legacy-duplicate-host");
        const char* const buffer_policy = persistent_vulkan_variant
            ? "mapped persistent Vulkan upload/download staging plus persistent Vulkan device buffers; direct BGRA8 staging fill and host output pack"
            : (persistent_host_variant
                ? "persistent checked-core host Mats; direct BGRA8 pack/unpack; ncnn-managed per-call Vulkan staging"
                : "persistent outer planar workspace plus checked-core host Mat allocation/copy per call");
        const char* const measurement_scope = persistent_vulkan_variant
            ? "host BGRA8 input fill directly into mapped persistent Vulkan upload staging, device upload, model execution, synchronized device download into mapped persistent Vulkan staging, and host BGRA8 output pack; includes real host transfer boundaries and is not GPU-native or kernel-only"
            : (persistent_host_variant
                ? "host BGRA8 input through persistent checked-core host Mats, host-recorded ncnn upload/model/download round trip, and direct host BGRA8 output"
                : "host BGRA8 input through duplicate outer planar workspace conversion, checked-core host Mat allocation/copy and ncnn upload/model/download, then outer planar-to-BGRA8 output conversion");
        const uint64_t deadline_us = options.source_fps == 30 ? 27'000 : 33'000;
        const uint32_t stride = options.width * 4;
        const size_t frame_bytes = static_cast<size_t>(stride) * options.height;
        constexpr size_t guard_bytes = 4096;
        constexpr uint8_t guard_value = 0xA5;

        std::vector<uint8_t> frame0(frame_bytes);
        std::vector<uint8_t> frame1(frame_bytes);
        std::vector<uint8_t> output_storage(frame_bytes + guard_bytes * 2, guard_value);
        uint8_t* const output = output_storage.data() + guard_bytes;
        make_frame(frame0, options.width, options.height, 0);
        make_frame(frame1, options.width, options.height, 16);
        const std::vector<uint8_t> original_frame0 = frame0;
        const std::vector<uint8_t> original_frame1 = frame1;

        PlainVideoRifeConfig config{};
        config.struct_size = sizeof(config);
        config.width = options.width;
        config.height = options.height;
        config.gpu_index = options.gpu_index;
        config.inference_threads = 1;
        config.deadline_us = deadline_us;
        config.max_queue_depth = 1;
        // The benchmark must keep measuring even when the gate is missed.
        // Production integration may enable a short automatic cooldown.
        config.overload_cooldown_frames = 0;
        config.pipeline_mode = persistent_vulkan_variant
            ? PLAINVIDEO_RIFE_PIPELINE_PERSISTENT_VULKAN_STAGED
            : (persistent_host_variant
                ? PLAINVIDEO_RIFE_PIPELINE_PERSISTENT_HOST_BGRA8
                : PLAINVIDEO_RIFE_PIPELINE_LEGACY_DUPLICATE_HOST);

        char error[512]{};
        constexpr uint32_t generated_proof_count = 4;
        const uint32_t generated_proof_phases[generated_proof_count][2] = {
            {0, 16},
            {16, 32},
            {32, 48},
            {0, 16},
        };
        std::vector<uint64_t> generated_output_digests;
        std::vector<int32_t> generated_output_status_codes;
        std::vector<int32_t> generated_output_call_results;
        generated_output_digests.reserve(generated_proof_count);
        generated_output_status_codes.reserve(generated_proof_count);
        generated_output_call_results.reserve(generated_proof_count);
        bool generated_output_guards_intact = true;
        bool generated_output_inputs_unchanged = true;
        bool generated_output_all_statuses_generated = true;

        // Keep correctness evidence outside the timed handle. This scoped
        // handle uses the identical pipeline mode with deadline checks disabled
        // so every successful call exposes the actual generated output.
        {
            PlainVideoRifeConfig proof_config = config;
            proof_config.deadline_us = 0;
            PlainVideoRifeHandle* proof_handle = nullptr;
            const int32_t proof_create_result = plainvideo_rife_create(
                &proof_config, options.model_directory.c_str(), &proof_handle,
                error, sizeof(error));
            if (proof_create_result != PLAINVIDEO_RIFE_OK
                || proof_handle == nullptr) {
                throw std::runtime_error(
                    std::string("Generated-output proof initialization failed: ")
                    + error);
            }
            struct ProofHandleGuard {
                PlainVideoRifeHandle* value;
                ~ProofHandleGuard() { plainvideo_rife_destroy(value); }
            } proof_guard{proof_handle};

            std::vector<uint8_t> proof_frame0(frame_bytes);
            std::vector<uint8_t> proof_frame1(frame_bytes);
            std::vector<uint8_t> proof_output_storage(
                frame_bytes + guard_bytes * 2, guard_value);
            uint8_t* const proof_output =
                proof_output_storage.data() + guard_bytes;

            PlainVideoRifeRequest proof_request{};
            proof_request.struct_size = sizeof(proof_request);
            proof_request.frame0_stride_bytes = stride;
            proof_request.frame1_stride_bytes = stride;
            proof_request.output_bgra8 = proof_output;
            proof_request.output_stride_bytes = stride;
            proof_request.timestep = 0.5F;

            for (uint32_t index = 0; index < generated_proof_count; ++index) {
                make_frame(proof_frame0, options.width, options.height,
                           generated_proof_phases[index][0]);
                make_frame(proof_frame1, options.width, options.height,
                           generated_proof_phases[index][1]);
                const std::vector<uint8_t> proof_original_frame0 = proof_frame0;
                const std::vector<uint8_t> proof_original_frame1 = proof_frame1;
                std::fill(proof_output, proof_output + frame_bytes, uint8_t{0});

                proof_request.frame0_bgra8 = proof_frame0.data();
                proof_request.frame1_bgra8 = proof_frame1.data();
                PlainVideoRifeResult proof_result{};
                proof_result.struct_size = sizeof(proof_result);
                const int32_t proof_call_result = plainvideo_rife_process(
                    proof_handle, &proof_request, &proof_result,
                    error, sizeof(error));
                generated_output_call_results.push_back(proof_call_result);
                generated_output_status_codes.push_back(
                    static_cast<int32_t>(proof_result.status));
                generated_output_digests.push_back(
                    fnv1a64(proof_output, frame_bytes));
                generated_output_all_statuses_generated =
                    generated_output_all_statuses_generated
                    && proof_call_result == PLAINVIDEO_RIFE_OK
                    && proof_result.status == PLAINVIDEO_RIFE_STATUS_GENERATED
                    && proof_result.deadline_exceeded == 0;
                generated_output_inputs_unchanged =
                    generated_output_inputs_unchanged
                    && proof_frame0 == proof_original_frame0
                    && proof_frame1 == proof_original_frame1;
                generated_output_guards_intact =
                    generated_output_guards_intact
                    && std::all_of(
                        proof_output_storage.begin(),
                        proof_output_storage.begin() + guard_bytes,
                        [guard_value](uint8_t value) {
                            return value == guard_value;
                        })
                    && std::all_of(
                        proof_output_storage.end() - guard_bytes,
                        proof_output_storage.end(),
                        [guard_value](uint8_t value) {
                            return value == guard_value;
                        });
            }
        }

        const bool generated_output_changes_across_pairs =
            generated_output_digests.size() == generated_proof_count
            && generated_output_digests[0] != generated_output_digests[1]
            && generated_output_digests[0] != generated_output_digests[2]
            && generated_output_digests[1] != generated_output_digests[2];
        const bool generated_output_repeated_pair_deterministic =
            generated_output_digests.size() == generated_proof_count
            && generated_output_digests[0] == generated_output_digests[3];
        const bool generated_output_proof =
            generated_output_all_statuses_generated
            && generated_output_guards_intact
            && generated_output_inputs_unchanged
            && generated_output_changes_across_pairs
            && generated_output_repeated_pair_deterministic;

        PlainVideoRifeHandle* handle = nullptr;
        const auto initialization_started = std::chrono::steady_clock::now();
        const int32_t create_result = plainvideo_rife_create(
            &config, options.model_directory.c_str(), &handle, error, sizeof(error));
        const auto initialization_finished = std::chrono::steady_clock::now();
        if (create_result != PLAINVIDEO_RIFE_OK || handle == nullptr) {
            throw std::runtime_error(std::string("RIFE initialization failed: ") + error);
        }
        const double initialization_ms = std::chrono::duration<double, std::milli>(
            initialization_finished - initialization_started).count();

        struct HandleGuard {
            PlainVideoRifeHandle* value;
            ~HandleGuard() { plainvideo_rife_destroy(value); }
        } guard{handle};

        char device_name[256]{};
        if (plainvideo_rife_get_device_name(handle, device_name, sizeof(device_name))
            != PLAINVIDEO_RIFE_OK) {
            throw std::runtime_error("Could not read the selected Vulkan device name.");
        }

        PlainVideoRifeRequest request{};
        request.struct_size = sizeof(request);
        request.frame0_bgra8 = frame0.data();
        request.frame0_stride_bytes = stride;
        request.frame1_bgra8 = frame1.data();
        request.frame1_stride_bytes = stride;
        request.output_bgra8 = output;
        request.output_stride_bytes = stride;
        request.timestep = 0.5F;

        PlainVideoRifeResult process_result{};
        process_result.struct_size = sizeof(process_result);
        for (uint32_t index = 0; index < options.warmup; ++index) {
            const int32_t warmup_result = plainvideo_rife_process(
                handle, &request, &process_result, error, sizeof(error));
            const bool usable_status = process_result.status == PLAINVIDEO_RIFE_STATUS_GENERATED
                || (process_result.status == PLAINVIDEO_RIFE_STATUS_BYPASSED_OVERLOAD
                    && process_result.deadline_exceeded != 0);
            if (warmup_result != PLAINVIDEO_RIFE_OK || !usable_status) {
                throw std::runtime_error(std::string("Warmup inference failed: ") + error);
            }
        }
        plainvideo_rife_reset_stats(handle);

        std::vector<uint64_t> attempt_us;
        std::vector<uint64_t> return_us;
        std::vector<uint64_t> host_input_prepare_us;
        std::vector<uint64_t> gpu_round_trip_us;
        std::vector<uint64_t> host_output_pack_us;
        std::vector<uint64_t> core_path_us;
        std::vector<uint64_t> fallback_copy_us;
        attempt_us.reserve(options.iterations);
        return_us.reserve(options.iterations);
        host_input_prepare_us.reserve(options.iterations);
        gpu_round_trip_us.reserve(options.iterations);
        host_output_pack_us.reserve(options.iterations);
        core_path_us.reserve(options.iterations);
        fallback_copy_us.reserve(options.iterations);
        uint32_t deadline_misses = 0;
        uint32_t checked_deadline_fallbacks = 0;
        bool deadline_fallback_outputs_matched = true;
        bool timing_contract_proof = true;
        for (uint32_t index = 0; index < options.iterations; ++index) {
            std::fill(output, output + frame_bytes, uint8_t{0});
            process_result = {};
            process_result.struct_size = sizeof(process_result);
            const int32_t call_result = plainvideo_rife_process(
                handle, &request, &process_result, error, sizeof(error));
            const bool usable_status = process_result.status == PLAINVIDEO_RIFE_STATUS_GENERATED
                || (process_result.status == PLAINVIDEO_RIFE_STATUS_BYPASSED_OVERLOAD
                    && process_result.deadline_exceeded != 0);
            if (call_result != PLAINVIDEO_RIFE_OK || !usable_status) {
                throw std::runtime_error(std::string("Measured inference failed: ") + error);
            }
            attempt_us.push_back(process_result.attempt_us);
            return_us.push_back(process_result.elapsed_us);
            host_input_prepare_us.push_back(process_result.host_input_prepare_us);
            gpu_round_trip_us.push_back(process_result.gpu_round_trip_us);
            host_output_pack_us.push_back(process_result.host_output_pack_us);
            core_path_us.push_back(process_result.core_path_us);
            fallback_copy_us.push_back(process_result.fallback_copy_us);

            const bool attempt_missed_deadline = process_result.attempt_us > deadline_us;
            deadline_misses += attempt_missed_deadline;
            uint32_t required_timing_flags = PLAINVIDEO_RIFE_TIMING_HOST_INPUT
                | PLAINVIDEO_RIFE_TIMING_HOST_OUTPUT
                | PLAINVIDEO_RIFE_TIMING_CORE_PATH;
            if (candidate_variant) {
                required_timing_flags |= PLAINVIDEO_RIFE_TIMING_GPU_ROUND_TRIP;
            }
            timing_contract_proof = timing_contract_proof
                && (process_result.timing_flags & required_timing_flags)
                    == required_timing_flags
                && (candidate_variant
                    || ((process_result.timing_flags
                            & PLAINVIDEO_RIFE_TIMING_GPU_ROUND_TRIP) == 0
                        && process_result.gpu_round_trip_us == 0))
                && (process_result.deadline_exceeded != 0) == attempt_missed_deadline
                && process_result.elapsed_us >= process_result.attempt_us
                && (attempt_missed_deadline
                    ? ((process_result.timing_flags
                        & PLAINVIDEO_RIFE_TIMING_FALLBACK_COPY) != 0)
                    : ((process_result.timing_flags
                            & PLAINVIDEO_RIFE_TIMING_FALLBACK_COPY) == 0
                        && process_result.fallback_copy_us == 0));
            if (process_result.status == PLAINVIDEO_RIFE_STATUS_BYPASSED_OVERLOAD
                && process_result.deadline_exceeded != 0) {
                ++checked_deadline_fallbacks;
                deadline_fallback_outputs_matched = deadline_fallback_outputs_matched
                    && output_matches_fallback(frame0, output);
            }
        }
        const bool observed_deadline_fallback_proof = deadline_fallback_outputs_matched
            && checked_deadline_fallbacks == deadline_misses
            && timing_contract_proof;

        PlainVideoRifeStats measured_stats{};
        measured_stats.struct_size = sizeof(measured_stats);
        plainvideo_rife_get_stats(handle, &measured_stats);

        plainvideo_rife_reset_stats(handle);
        bool fallback_proof = true;
        struct BypassCase {
            uint32_t flags;
            uint32_t expected_status;
        };
        const BypassCase bypass_cases[] = {
            {PLAINVIDEO_RIFE_FLAG_SCENE_CHANGE,
             PLAINVIDEO_RIFE_STATUS_BYPASSED_SCENE_CHANGE},
            {PLAINVIDEO_RIFE_FLAG_DISCONTINUITY,
             PLAINVIDEO_RIFE_STATUS_BYPASSED_DISCONTINUITY},
            {PLAINVIDEO_RIFE_FLAG_OVERLOADED,
             PLAINVIDEO_RIFE_STATUS_BYPASSED_OVERLOAD},
        };
        for (const BypassCase& bypass_case : bypass_cases) {
            std::fill(output, output + frame_bytes, uint8_t{0});
            request.flags = bypass_case.flags;
            request.queue_depth = 0;
            process_result = {};
            process_result.struct_size = sizeof(process_result);
            fallback_proof = fallback_proof
                && plainvideo_rife_process(handle, &request, &process_result,
                                           error, sizeof(error)) == PLAINVIDEO_RIFE_OK
                && process_result.status == bypass_case.expected_status
                && output_matches_fallback(frame0, output);
        }
        std::fill(output, output + frame_bytes, uint8_t{0});
        request.flags = PLAINVIDEO_RIFE_FLAG_NONE;
        request.queue_depth = config.max_queue_depth + 1;
        process_result = {};
        process_result.struct_size = sizeof(process_result);
        fallback_proof = fallback_proof
            && plainvideo_rife_process(handle, &request, &process_result,
                                       error, sizeof(error)) == PLAINVIDEO_RIFE_OK
            && process_result.status == PLAINVIDEO_RIFE_STATUS_BYPASSED_OVERLOAD
            && output_matches_fallback(frame0, output);

        PlainVideoRifeStats bypass_stats{};
        bypass_stats.struct_size = sizeof(bypass_stats);
        plainvideo_rife_get_stats(handle, &bypass_stats);
        fallback_proof = fallback_proof
            && bypass_stats.generated_frames == 0
            && bypass_stats.bypassed_scene_changes == 1
            && bypass_stats.bypassed_discontinuities == 1
            && bypass_stats.bypassed_overload_frames == 2
            && bypass_stats.missed_frames == 0;

        constexpr uint8_t invalid_request_sentinel = 0x3C;
        std::fill(output, output + frame_bytes, invalid_request_sentinel);
        request.timestep = std::numeric_limits<float>::quiet_NaN();
        request.queue_depth = 0;
        process_result = {};
        process_result.struct_size = sizeof(process_result);
        const bool non_finite_timestep_rejected = plainvideo_rife_process(
            handle, &request, &process_result, error, sizeof(error))
            == PLAINVIDEO_RIFE_ERROR_INVALID_ARGUMENT;
        const bool invalid_request_output_unchanged = std::all_of(
            output, output + frame_bytes,
            [](uint8_t value) { return value == invalid_request_sentinel; });
        request.timestep = 0.5F;
        request.output_bgra8 = frame0.data();
        process_result = {};
        process_result.struct_size = sizeof(process_result);
        const bool overlapping_buffers_rejected = plainvideo_rife_process(
            handle, &request, &process_result, error, sizeof(error))
            == PLAINVIDEO_RIFE_ERROR_INVALID_ARGUMENT;
        request.output_bgra8 = output;
        const bool input_validation_proof = non_finite_timestep_rejected
            && invalid_request_output_unchanged
            && overlapping_buffers_rejected;

        PlainVideoRifeConfig forced_deadline_config = config;
        forced_deadline_config.deadline_us = 1;
        forced_deadline_config.overload_cooldown_frames = 0;
        PlainVideoRifeHandle* forced_deadline_handle = nullptr;
        bool forced_deadline_fallback_proof = false;
        const int32_t forced_create_result = plainvideo_rife_create(
            &forced_deadline_config, options.model_directory.c_str(),
            &forced_deadline_handle, error, sizeof(error));
        if (forced_create_result == PLAINVIDEO_RIFE_OK
            && forced_deadline_handle != nullptr) {
            struct ForcedHandleGuard {
                PlainVideoRifeHandle* value;
                ~ForcedHandleGuard() { plainvideo_rife_destroy(value); }
            } forced_guard{forced_deadline_handle};

            std::fill(output, output + frame_bytes, uint8_t{0});
            request.flags = PLAINVIDEO_RIFE_FLAG_NONE;
            request.queue_depth = 0;
            process_result = {};
            process_result.struct_size = sizeof(process_result);
            const int32_t forced_process_result = plainvideo_rife_process(
                forced_deadline_handle, &request, &process_result,
                error, sizeof(error));
            PlainVideoRifeStats forced_stats{};
            forced_stats.struct_size = sizeof(forced_stats);
            const int32_t forced_stats_result = plainvideo_rife_get_stats(
                forced_deadline_handle, &forced_stats);
            forced_deadline_fallback_proof =
                forced_process_result == PLAINVIDEO_RIFE_OK
                && forced_stats_result == PLAINVIDEO_RIFE_OK
                && process_result.status == PLAINVIDEO_RIFE_STATUS_BYPASSED_OVERLOAD
                && process_result.deadline_exceeded != 0
                && output_matches_fallback(frame0, output)
                && forced_stats.generated_frames == 0
                && forced_stats.bypassed_overload_frames == 1
                && forced_stats.missed_frames == 0;
        }
        const bool deadline_fallback_proof = observed_deadline_fallback_proof
            && forced_deadline_fallback_proof;

        const double attempt_p95_ms = percentile(attempt_us, 0.95);
        const double return_p95_ms = percentile(return_us, 0.95);
        const double core_path_p95_ms = percentile(core_path_us, 0.95);
        const double gpu_round_trip_p95_ms = percentile(gpu_round_trip_us, 0.95);
        const double limit_ms = static_cast<double>(deadline_us) / 1000.0;
        const bool guards_intact = std::all_of(
            output_storage.begin(), output_storage.begin() + guard_bytes,
            [guard_value](uint8_t value) { return value == guard_value; })
            && std::all_of(
                output_storage.end() - guard_bytes, output_storage.end(),
                [guard_value](uint8_t value) { return value == guard_value; });
        const bool inputs_unchanged = frame0 == original_frame0 && frame1 == original_frame1;
        const bool memory_contract_proof = guards_intact && inputs_unchanged;
        const uint64_t measured_bypasses = measured_stats.bypassed_scene_changes
            + measured_stats.bypassed_discontinuities
            + measured_stats.bypassed_overload_frames;
        const uint32_t max_deadline_misses = options.iterations
            - static_cast<uint32_t>(std::ceil(0.95 * options.iterations));
        const bool performance_gate_passed = attempt_p95_ms <= limit_ms
            && return_p95_ms <= limit_ms
            && core_path_p95_ms <= limit_ms
            && (!candidate_variant || gpu_round_trip_p95_ms <= limit_ms)
            && deadline_misses <= max_deadline_misses
            && measured_stats.generated_frames == options.iterations - deadline_misses
            && measured_bypasses == deadline_misses
            && measured_stats.missed_frames == 0
            && deadline_fallback_proof
            && fallback_proof
            && input_validation_proof
            && memory_contract_proof
            && timing_contract_proof
            && generated_output_proof;

        std::ostringstream json;
        json << std::fixed << std::setprecision(3)
             << "{\n"
             << "  \"schemaVersion\": 2,\n"
             << "  \"abiVersion\": " << plainvideo_rife_abi_version() << ",\n"
             << "  \"model\": \"RIFE 4.25-lite\",\n"
             << "  \"runtime\": \"ncnn/Vulkan\",\n"
             << "  \"device\": \"" << escape_json(device_name) << "\",\n"
             << "  \"variantId\": \"" << variant_id << "\",\n"
             << "  \"comparisonClass\": \"host-bgra8-to-host-bgra8\",\n"
             << "  \"bufferPolicy\": \"" << escape_json(buffer_policy) << "\",\n"
             << "  \"input\": {\"width\": " << options.width
             << ", \"height\": " << options.height
             << ", \"pixelFormat\": \"BGRA8 SDR\", \"sourceFps\": "
             << options.source_fps << ", \"targetFps\": "
             << options.source_fps * 2 << "},\n"
             << "  \"measurementScope\": \""
             << escape_json(measurement_scope) << "\",\n"
             << "  \"stageAvailability\": {\"hostInputPrepare\": true, "
             << "\"gpuRoundTrip\": "
             << (candidate_variant ? "true" : "false")
             << ", \"hostOutputPack\": true, \"corePath\": true, "
             << "\"fallbackCopy\": true},\n"
             << "  \"timingDescription\": {\"gpuRoundTrip\": "
             << "\"CPU steady-clock wall time around ncnn command setup, upload, "
             << "model execution, synchronized download, and wait; not a Vulkan "
             << "timestamp or kernel-only timing\"},\n"
             << "  \"warmupFrames\": " << options.warmup << ",\n"
             << "  \"measuredFrames\": " << options.iterations << ",\n"
             << "  \"initializationMs\": " << initialization_ms << ",\n"
             << "  \"attemptTimingMs\": ";
        append_timing_summary(json, attempt_us);
        json << ",\n  \"timingMs\": ";
        append_timing_summary(json, return_us);
        json << ",\n  \"corePathTimingMs\": ";
        append_timing_summary(json, core_path_us);
        json << ",\n  \"gpuRoundTripTimingMs\": ";
        append_timing_summary(json, gpu_round_trip_us);
        json << ",\n"
             << "  \"stageMeanMs\": {\"hostInputPrepare\": "
             << average_ms(host_input_prepare_us)
             << ", \"ncnnGpuRoundTrip\": " << average_ms(gpu_round_trip_us)
             << ", \"hostOutputPack\": " << average_ms(host_output_pack_us)
             << ", \"corePath\": " << average_ms(core_path_us)
             << ", \"fallbackCopy\": " << average_ms(fallback_copy_us) << "},\n"
             << "  \"samplesUs\": {\"attemptEndToEnd\": ";
        append_samples(json, attempt_us);
        json << ", \"returnEndToEnd\": ";
        append_samples(json, return_us);
        json << ", \"hostInputPrepare\": ";
        append_samples(json, host_input_prepare_us);
        json << ", \"corePath\": ";
        append_samples(json, core_path_us);
        json << ", \"ncnnGpuRoundTrip\": ";
        append_samples(json, gpu_round_trip_us);
        json << ", \"hostOutputPack\": ";
        append_samples(json, host_output_pack_us);
        json << ", \"fallbackCopy\": ";
        append_samples(json, fallback_copy_us);
        json << "},\n"
             << "  \"performanceGate\": {\"p95LimitMs\": " << limit_ms
             << ", \"attemptP95Ms\": " << attempt_p95_ms
             << ", \"returnEndToEndP95Ms\": " << return_p95_ms
             << ", \"corePathP95Ms\": " << core_path_p95_ms
             << ", \"gpuRoundTripP95Ms\": " << gpu_round_trip_p95_ms
             << ", \"deadlineMisses\": " << deadline_misses
             << ", \"maxDeadlineMisses\": " << max_deadline_misses
             << ", \"passed\": " << (performance_gate_passed ? "true" : "false") << "},\n"
             << "  \"measuredCounts\": {\"generated\": "
             << measured_stats.generated_frames
             << ", \"bypassed\": "
             << measured_bypasses
             << ", \"missed\": " << measured_stats.missed_frames << "},\n"
             << "  \"deadlineFallbackProof\": {\"passed\": "
             << (deadline_fallback_proof ? "true" : "false")
             << ", \"observedLateFramesMatched\": "
             << (observed_deadline_fallback_proof ? "true" : "false")
             << ", \"observedCheckedFrames\": " << checked_deadline_fallbacks
             << ", \"forcedOneMicrosecondDeadlinePassed\": "
             << (forced_deadline_fallback_proof ? "true" : "false") << "},\n"
             << "  \"fallbackProof\": {\"passed\": "
             << (fallback_proof ? "true" : "false")
             << ", \"sceneChangeBypasses\": " << bypass_stats.bypassed_scene_changes
             << ", \"discontinuityBypasses\": " << bypass_stats.bypassed_discontinuities
             << ", \"overloadBypasses\": " << bypass_stats.bypassed_overload_frames
             << ", \"missed\": " << bypass_stats.missed_frames << "},\n"
             << "  \"inputValidationProof\": {\"passed\": "
             << (input_validation_proof ? "true" : "false")
             << ", \"nonFiniteTimestepRejected\": "
             << (non_finite_timestep_rejected ? "true" : "false")
             << ", \"overlappingBuffersRejected\": "
             << (overlapping_buffers_rejected ? "true" : "false")
             << ", \"outputUnchanged\": "
             << (invalid_request_output_unchanged ? "true" : "false") << "},\n"
             << "  \"generatedOutputProof\": {\"passed\": "
             << (generated_output_proof ? "true" : "false")
             << ", \"status\": \""
             << (generated_output_all_statuses_generated
                    ? "all-generated" : "failed")
             << "\", \"count\": " << generated_output_digests.size()
             << ", \"allStatusesGenerated\": "
             << (generated_output_all_statuses_generated ? "true" : "false")
             << ", \"outputGuardsIntact\": "
             << (generated_output_guards_intact ? "true" : "false")
             << ", \"inputsUnchanged\": "
             << (generated_output_inputs_unchanged ? "true" : "false")
             << ", \"outputChangesAcrossPairs\": "
             << (generated_output_changes_across_pairs ? "true" : "false")
             << ", \"repeatedPairDeterministic\": "
             << (generated_output_repeated_pair_deterministic ? "true" : "false")
             << ", \"digestAlgorithm\": \"FNV-1a-64\""
             << ", \"digestScope\": \"full row-major 1920x1080 BGRA8 output bytes\""
             << ", \"inputPhasePairs\": [[0,16],[16,32],[32,48],[0,16]]"
             << ", \"callReturnCodes\": [";
        for (size_t index = 0; index < generated_output_call_results.size(); ++index) {
            if (index > 0) {
                json << ',';
            }
            json << generated_output_call_results[index];
        }
        json << "], \"statusCodes\": [";
        for (size_t index = 0; index < generated_output_status_codes.size(); ++index) {
            if (index > 0) {
                json << ',';
            }
            json << generated_output_status_codes[index];
        }
        json << "], \"digests\": [";
        for (size_t index = 0; index < generated_output_digests.size(); ++index) {
            if (index > 0) {
                json << ',';
            }
            json << '\"' << format_digest(generated_output_digests[index]) << '\"';
        }
        json << "]},\n"
             << "  \"timingContractProof\": {\"passed\": "
             << (timing_contract_proof ? "true" : "false")
             << ", \"deadlineMissesDerivedFromAttempt\": true, "
             << "\"gpuRoundTripIsHostRecorded\": true},\n"
             << "  \"memoryContractProof\": {\"passed\": "
             << (memory_contract_proof ? "true" : "false")
             << ", \"inputsUnchanged\": " << (inputs_unchanged ? "true" : "false")
             << ", \"outputGuardsIntact\": " << (guards_intact ? "true" : "false") << "}\n"
             << "}\n";

        const std::string output_json = json.str();
        std::cout << output_json;
        if (!options.json_path.empty()) {
            const std::filesystem::path output_path(options.json_path);
            if (output_path.has_parent_path()) {
                std::filesystem::create_directories(output_path.parent_path());
            }
            std::ofstream output_file(output_path, std::ios::binary | std::ios::trunc);
            if (!output_file) {
                throw std::runtime_error("Could not create JSON output: " + options.json_path);
            }
            output_file << output_json;
        }

        return performance_gate_passed ? 0 : 2;
    } catch (const std::exception& error) {
        std::cerr << "plainvideo_rife_bench: " << error.what() << '\n';
        return 1;
    }
}
