#ifndef PLAINVIDEO_RIFE_PREPROC_BGRA8_H
#define PLAINVIDEO_RIFE_PREPROC_BGRA8_H

// Product-boundary preprocessor for the persistent Vulkan path. Input pixels
// are uploaded as packed BGRA8 uints and expanded to R/G/B model planes on the
// GPU, avoiding two 24 MiB CPU float conversion buffers per frame pair.
static const char plainvideo_rife_preproc_bgra8_comp_data[] = R"glsl(
#version 450

#if NCNN_fp16_storage
#extension GL_EXT_shader_16bit_storage: require
#endif

layout (binding = 0) readonly buffer bottom_blob { uint bottom_blob_data[]; };
layout (binding = 1) writeonly buffer top_blob { sfp top_blob_data[]; };

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
    int gz = int(gl_GlobalInvocationID.z);

    if (gx >= p.outw || gy >= p.outh || gz >= 3)
        return;

    int destination = gz * p.outcstep + gy * p.outw + gx;
    if (gx >= p.w || gy >= p.h)
    {
        top_blob_data[destination] = sfp(0.0);
        return;
    }

    uint pixel = bottom_blob_data[gy * p.w + gx];
    uint shift = gz == 0 ? 16 : (gz == 1 ? 8 : 0);
    float channel = float((pixel >> shift) & 255u) * (1.0 / 255.0);
    top_blob_data[destination] = sfp(channel);
}
)glsl";

#endif // PLAINVIDEO_RIFE_PREPROC_BGRA8_H
