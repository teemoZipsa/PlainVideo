#ifndef PLAINVIDEO_RIFE_CONCAT7_H
#define PLAINVIDEO_RIFE_CONCAT7_H

#include "layer.h"

#include <cstdint>

ncnn::Layer* plainvideo_rife_concat7_layer_creator(void* userdata);
void plainvideo_rife_concat7_reset_thread_stats() noexcept;
std::uint32_t plainvideo_rife_concat7_thread_fused_calls() noexcept;
std::uint32_t plainvideo_rife_concat7_thread_fallback_calls() noexcept;

#endif // PLAINVIDEO_RIFE_CONCAT7_H
