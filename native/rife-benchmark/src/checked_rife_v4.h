#ifndef PLAINVIDEO_CHECKED_RIFE_V4_H
#define PLAINVIDEO_CHECKED_RIFE_V4_H

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>

struct CheckedRifeV4Timings {
    std::uint64_t host_input_prepare_us = 0;
    std::uint64_t gpu_path_us = 0;
    std::uint64_t host_output_pack_us = 0;
    std::uint64_t core_path_us = 0;
};

// CheckedRifeV4 does not own the process-wide ncnn GPU instance. The caller
// must keep that instance alive until the core and all in-flight calls are
// destroyed, matching ncnn's external Vulkan-device lifetime contract.
class CheckedRifeV4 {
public:
    CheckedRifeV4(int gpu_index,
                  int inference_threads,
                  bool enable_persistent_vulkan = false);
    ~CheckedRifeV4();

    CheckedRifeV4(const CheckedRifeV4&) = delete;
    CheckedRifeV4& operator=(const CheckedRifeV4&) = delete;

    int load(const std::wstring& model_directory, std::string& error);

    int process(const float* src0_r,
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
                std::string& error) const;

    // Direct 1920x1080 BGRA8 boundary used to measure host preparation and
    // packing separately from upload, inference, and download. Alpha input is
    // ignored and generated output alpha is opaque. Calls are serialized
    // because the host ncnn Mats are allocated once and reused.
    int process_bgra8(const std::uint8_t* src0_bgra,
                      std::ptrdiff_t src0_stride_bytes,
                      const std::uint8_t* src1_bgra,
                      std::ptrdiff_t src1_stride_bytes,
                      std::uint8_t* dst_bgra,
                      std::ptrdiff_t dst_stride_bytes,
                      float timestep,
                      CheckedRifeV4Timings& timings,
                      std::string& error) const;

    // Host-BGRA8 boundary backed by load-time persistent Vulkan allocators,
    // mapped upload/download staging, command state, and fixed pre/postprocess
    // buffers. This remains a staged host round trip, not a GPU-native input
    // contract. It is available only when enabled in the constructor.
    int process_bgra8_persistent_vulkan(
        const std::uint8_t* src0_bgra,
        std::ptrdiff_t src0_stride_bytes,
        const std::uint8_t* src1_bgra,
        std::ptrdiff_t src1_stride_bytes,
        std::uint8_t* dst_bgra,
        std::ptrdiff_t dst_stride_bytes,
        float timestep,
        CheckedRifeV4Timings& timings,
        std::string& error) const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

#endif // PLAINVIDEO_CHECKED_RIFE_V4_H
