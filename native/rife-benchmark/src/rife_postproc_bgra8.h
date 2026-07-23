#ifndef PLAINVIDEO_RIFE_POSTPROC_BGRA8_H
#define PLAINVIDEO_RIFE_POSTPROC_BGRA8_H

// Product-boundary postprocessor for the persistent Vulkan path. The upstream
// RIFE shader downloads three planar float channels and leaves BGRA packing to
// the CPU. Writing one packed BGRA8 pixel per invocation keeps the conversion
// on the GPU and cuts the download from 24 MiB to 8 MiB at 1080p.
static const char plainvideo_rife_postproc_bgra8_comp_data[] = R"glsl(
#version 450

#if NCNN_fp16_storage
#extension GL_EXT_shader_16bit_storage: require
#endif

layout (binding = 0) readonly buffer bottom_blob { sfp bottom_blob_data[]; };
layout (binding = 1) writeonly buffer top_blob { uint top_blob_data[]; };

layout (push_constant) uniform parameter
{
int w;
int h;
int cstep;

int outw;
int outh;
int outcstep;
} p;

void main()
{
    int gx = int(gl_GlobalInvocationID.x);
    int gy = int(gl_GlobalInvocationID.y);

    if (gx >= p.outw || gy >= p.outh)
        return;

    int source = gy * p.w + gx;
    float red = float(bottom_blob_data[source]);
    float green = float(bottom_blob_data[p.cstep + source]);
    float blue = float(bottom_blob_data[2 * p.cstep + source]);

    int destination = gy * p.outw + gx;
    if (isnan(red) || isinf(red) || isnan(green) || isinf(green)
        || isnan(blue) || isinf(blue))
    {
        // Alpha zero is an internal invalid-output sentinel. Valid product
        // output is always opaque and the host boundary rejects this frame.
        top_blob_data[destination] = 0u;
        return;
    }

    // Preserve the established host-boundary byte contract. The upstream
    // float postprocessor adds 0.5 before download and the checked host packer
    // rounds once more, so the packed GPU path must use the same +1.0 result.
    uint rv = clamp(uint(floor(red * 255.0 + 1.0)), 0, 255);
    uint gv = clamp(uint(floor(green * 255.0 + 1.0)), 0, 255);
    uint bv = clamp(uint(floor(blue * 255.0 + 1.0)), 0, 255);
    top_blob_data[destination] = bv + gv * 256
        + rv * 65536 + uint(255) * 16777216;
}
)glsl";

#endif // PLAINVIDEO_RIFE_POSTPROC_BGRA8_H
