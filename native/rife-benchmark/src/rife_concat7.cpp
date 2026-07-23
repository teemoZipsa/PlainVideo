#include "rife_concat7.h"

#include "gpu.h"
#include "pipeline.h"

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string_view>
#include <vector>

namespace {

constexpr std::size_t kInputCount = 7;
thread_local std::uint32_t g_fused_calls = 0;
thread_local std::uint32_t g_fallback_calls = 0;

constexpr const char kConcat7Shader[] = R"glsl(
#version 450

layout (binding = 0) readonly buffer input0 { sfp input0_data[]; };
layout (binding = 1) readonly buffer input1 { sfp input1_data[]; };
layout (binding = 2) readonly buffer input2 { sfpvec4 input2_data[]; };
layout (binding = 3) readonly buffer input3 { sfpvec4 input3_data[]; };
layout (binding = 4) readonly buffer input4 { sfp input4_data[]; };
layout (binding = 5) readonly buffer input5 { sfp input5_data[]; };
layout (binding = 6) readonly buffer input6 { sfpvec4 input6_data[]; };
layout (binding = 7) writeonly buffer output_blob {
    sfpvec4 output_data[];
};

layout (push_constant) uniform parameter
{
    int w;
    int h;
    int cstep;
} p;

void main()
{
    int x = int(gl_GlobalInvocationID.x);
    int y = int(gl_GlobalInvocationID.y);
    if (x >= p.w || y >= p.h)
        return;

    int xy = y * p.w + x;
    afpvec4 input2_value = buffer_ld4(input2_data, xy);
    afpvec4 input3_value = buffer_ld4(input3_data, xy);

    afpvec4 output0 = afpvec4(
        buffer_ld1(input0_data, xy),
        buffer_ld1(input0_data, p.cstep + xy),
        buffer_ld1(input0_data, 2 * p.cstep + xy),
        buffer_ld1(input1_data, xy));
    afpvec4 output1 = afpvec4(
        buffer_ld1(input1_data, p.cstep + xy),
        buffer_ld1(input1_data, 2 * p.cstep + xy),
        input2_value.r,
        input2_value.g);
    afpvec4 output2 = afpvec4(
        input2_value.b,
        input2_value.a,
        input3_value.r,
        input3_value.g);
    afpvec4 output3 = afpvec4(
        input3_value.b,
        input3_value.a,
        buffer_ld1(input4_data, xy),
        buffer_ld1(input5_data, xy));
    afpvec4 output4 = buffer_ld4(input6_data, xy);
    afpvec4 output5 = buffer_ld4(input6_data, p.cstep + xy);

    buffer_st4(output_data, xy, output0);
    buffer_st4(output_data, p.cstep + xy, output1);
    buffer_st4(output_data, 2 * p.cstep + xy, output2);
    buffer_st4(output_data, 3 * p.cstep + xy, output3);
    buffer_st4(output_data, 4 * p.cstep + xy, output4);
    buffer_st4(output_data, 5 * p.cstep + xy, output5);
}
)glsl";

bool is_target_concat(std::string_view name) {
    return name == "Concat_139"
        || name == "Concat_240"
        || name == "Concat_341"
        || name == "Concat_442";
}

class PlainVideoRifeConcat7 final : public ncnn::Layer {
public:
    PlainVideoRifeConcat7()
        : fallback_(ncnn::create_layer_vulkan("Concat")) {
        one_blob_only = false;
        support_inplace = false;
        support_vulkan = true;
        support_packing = true;
        support_fp16_storage = true;
        support_image_storage = false;
    }

    ~PlainVideoRifeConcat7() override = default;

    int load_param(const ncnn::ParamDict& parameters) override {
        axis_ = parameters.get(0, 0);
        return fallback_ != nullptr
            ? fallback_->load_param(parameters)
            : -1;
    }

    int load_model(const ncnn::ModelBin& model) override {
        return fallback_ != nullptr
            ? fallback_->load_model(model)
            : -1;
    }

    int create_pipeline(const ncnn::Option& option) override {
        if (fallback_ == nullptr || vkdev == nullptr) {
            return -1;
        }
        fallback_->vkdev = vkdev;
        fallback_->bottom_shapes = bottom_shapes;
        fallback_->top_shapes = top_shapes;
        const int fallback_result = fallback_->create_pipeline(option);
        if (fallback_result != 0) {
            return fallback_result;
        }
        if (!is_target_concat(name)) {
            return 0;
        }

        std::vector<std::uint32_t> spirv;
        {
            std::lock_guard lock(shader_mutex_);
            if (shader_spirv_.empty()) {
                const int compile_result = ncnn::compile_spirv_module(
                    kConcat7Shader,
                    static_cast<int>(sizeof(kConcat7Shader) - 1),
                    option,
                    shader_spirv_);
                if (compile_result != 0) {
                    return 0;
                }
            }
            spirv = shader_spirv_;
        }

        auto pipeline = std::make_unique<ncnn::Pipeline>(vkdev);
        pipeline->set_optimal_local_size_xyz(8, 8, 1);
        const std::vector<ncnn::vk_specialization_type> specializations;
        const int create_result = pipeline->create(
            spirv.data(),
            spirv.size() * sizeof(std::uint32_t),
            specializations);
        if (create_result == 0) {
            fused_pipeline_ = std::move(pipeline);
        }
        return 0;
    }

    int destroy_pipeline(const ncnn::Option& option) override {
        fused_pipeline_.reset();
        return fallback_ != nullptr
            ? fallback_->destroy_pipeline(option)
            : 0;
    }

    int forward(const std::vector<ncnn::Mat>& bottom_blobs,
                std::vector<ncnn::Mat>& top_blobs,
                const ncnn::Option& option) const override {
        return fallback_ != nullptr
            ? fallback_->forward(bottom_blobs, top_blobs, option)
            : -1;
    }

    int forward(const std::vector<ncnn::VkMat>& bottom_blobs,
                std::vector<ncnn::VkMat>& top_blobs,
                ncnn::VkCompute& command,
                const ncnn::Option& option) const override {
        if (!can_fuse(bottom_blobs)) {
            if (is_target_concat(name)) {
                ++g_fallback_calls;
            }
            return fallback_ != nullptr
                ? fallback_->forward(
                    bottom_blobs, top_blobs, command, option)
                : -1;
        }

        const int width = bottom_blobs[0].w;
        const int height = bottom_blobs[0].h;
        const std::size_t scalar_size =
            bottom_blobs[0].elemsize / bottom_blobs[0].elempack;
        int scalar_channels = 0;
        for (const ncnn::VkMat& input : bottom_blobs) {
            scalar_channels += input.c * input.elempack;
        }

        ncnn::VkMat& output = top_blobs[0];
        output.create(
            width,
            height,
            scalar_channels / 4,
            scalar_size * 4,
            4,
            option.blob_vkallocator);
        if (output.empty()) {
            return -100;
        }

        std::vector<ncnn::VkMat> bindings;
        bindings.reserve(kInputCount + 1);
        bindings.insert(
            bindings.end(), bottom_blobs.begin(), bottom_blobs.end());
        bindings.push_back(output);

        std::vector<ncnn::vk_constant_type> constants(3);
        constants[0].i = width;
        constants[1].i = height;
        constants[2].i = static_cast<int>(output.cstep);
        ncnn::Mat dispatcher(width, height, 1, nullptr);
        command.record_pipeline(
            fused_pipeline_.get(),
            bindings,
            std::vector<ncnn::VkImageMat>(),
            constants,
            dispatcher);
        ++g_fused_calls;
        return 0;
    }

    int forward(const std::vector<ncnn::VkImageMat>& bottom_blobs,
                std::vector<ncnn::VkImageMat>& top_blobs,
                ncnn::VkCompute& command,
                const ncnn::Option& option) const override {
        return fallback_ != nullptr
            ? fallback_->forward(
                bottom_blobs, top_blobs, command, option)
            : -1;
    }

private:
    bool can_fuse(const std::vector<ncnn::VkMat>& inputs) const {
        if (fused_pipeline_ == nullptr
            || !is_target_concat(name)
            || axis_ != 0
            || inputs.size() != kInputCount
            || inputs[0].dims != 3) {
            return false;
        }

        const int width = inputs[0].w;
        const int height = inputs[0].h;
        const std::size_t scalar_size =
            inputs[0].elemsize / inputs[0].elempack;
        const std::size_t cstep = inputs[0].cstep;
        constexpr std::array<int, kInputCount> expected_channels{
            3, 3, 1, 1, 1, 1, 2};
        constexpr std::array<int, kInputCount> expected_packing{
            1, 1, 4, 4, 1, 1, 4};
        for (std::size_t index = 0; index < inputs.size(); ++index) {
            const ncnn::VkMat& input = inputs[index];
            if (input.empty()
                || input.dims != 3
                || input.w != width
                || input.h != height
                || input.c != expected_channels[index]
                || input.elempack != expected_packing[index]
                || input.elemsize / input.elempack != scalar_size
                || input.cstep != cstep) {
                return false;
            }
        }
        return scalar_size == 2U || scalar_size == 4U;
    }

    int axis_ = 0;
    std::unique_ptr<ncnn::Layer> fallback_;
    std::unique_ptr<ncnn::Pipeline> fused_pipeline_;

    static std::mutex shader_mutex_;
    static std::vector<std::uint32_t> shader_spirv_;
};

std::mutex PlainVideoRifeConcat7::shader_mutex_;
std::vector<std::uint32_t> PlainVideoRifeConcat7::shader_spirv_;

} // namespace

ncnn::Layer* plainvideo_rife_concat7_layer_creator(void*) {
    return new PlainVideoRifeConcat7;
}

void plainvideo_rife_concat7_reset_thread_stats() noexcept {
    g_fused_calls = 0;
    g_fallback_calls = 0;
}

std::uint32_t plainvideo_rife_concat7_thread_fused_calls() noexcept {
    return g_fused_calls;
}

std::uint32_t plainvideo_rife_concat7_thread_fallback_calls() noexcept {
    return g_fallback_calls;
}
