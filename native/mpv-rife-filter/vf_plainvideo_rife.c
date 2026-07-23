/*
 * PlainVideo's opt-in RIFE frame-doubling bridge for the pinned mpv v0.41.0
 * source tree. This file is compiled into libmpv, but loads the independently
 * built plainvideo_rife.dll only when the filter is explicitly enabled.
 *
 * Copyright (c) 2026 PlainVideo contributors
 * SPDX-License-Identifier: LGPL-2.1-or-later
 */

#include <math.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>

#include "common/common.h"
#include "filters/filter.h"
#include "filters/filter_internal.h"
#include "filters/user_filters.h"
#include "options/m_option.h"
#include "video/img_format.h"
#include "video/mp_image.h"
#include "video/filter/refqueue.h"

#define PV_RIFE_ABI_VERSION 2u
#define PV_RIFE_OK 0
#define PV_RIFE_STATUS_GENERATED 0u
#define PV_RIFE_STATUS_BYPASSED_SCENE_CHANGE 1u
#define PV_RIFE_STATUS_BYPASSED_DISCONTINUITY 2u
#define PV_RIFE_STATUS_BYPASSED_OVERLOAD 3u
#define PV_RIFE_STATUS_BYPASSED_ERROR 4u
#define PV_RIFE_FLAG_SCENE_CHANGE (1u << 0)
#define PV_RIFE_FLAG_DISCONTINUITY (1u << 1)
#define PV_RIFE_FLAG_OVERLOADED (1u << 2)
#define PV_RIFE_PIPELINE_PERSISTENT_VULKAN_STAGED 2u
#define PV_RIFE_TASK_CAPACITY 2
#define PV_RIFE_TIMING_SAMPLE_CAPACITY 2048

typedef struct PlainVideoRifeHandle PlainVideoRifeHandle;

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
    const uint8_t *frame0_bgra8;
    uint32_t frame0_stride_bytes;
    const uint8_t *frame1_bgra8;
    uint32_t frame1_stride_bytes;
    uint8_t *output_bgra8;
    uint32_t output_stride_bytes;
    float timestep;
    uint32_t flags;
    uint32_t queue_depth;
} PlainVideoRifeRequest;

typedef struct PlainVideoRifeResult {
    uint32_t struct_size;
    uint32_t status;
    uint64_t attempt_us;
    uint64_t elapsed_us;
    uint64_t host_input_prepare_us;
    uint64_t gpu_round_trip_us;
    uint64_t host_output_pack_us;
    uint64_t core_path_us;
    uint64_t fallback_copy_us;
    uint32_t deadline_exceeded;
    uint32_t timing_flags;
} PlainVideoRifeResult;

typedef uint32_t (__cdecl *rife_abi_version_fn)(void);
typedef int32_t (__cdecl *rife_create_fn)(const PlainVideoRifeConfig *,
                                         const char *, PlainVideoRifeHandle **,
                                         char *, size_t);
typedef void (__cdecl *rife_destroy_fn)(PlainVideoRifeHandle *);
typedef int32_t (__cdecl *rife_process_fn)(PlainVideoRifeHandle *,
                                          const PlainVideoRifeRequest *,
                                          PlainVideoRifeResult *, char *, size_t);
typedef int32_t (__cdecl *rife_reset_stats_fn)(PlainVideoRifeHandle *);
typedef int32_t (__cdecl *rife_device_name_fn)(const PlainVideoRifeHandle *,
                                              char *, size_t);

struct rife_opts {
    int gpu_index;
    int deadline_us;
    int scene_threshold;
    double max_source_fps;
};

struct priv {
    struct rife_opts *opts;
    struct mp_refqueue *queue;
    HMODULE runtime_module;
    PlainVideoRifeHandle *runtime;
    rife_destroy_fn destroy;
    rife_process_fn process;
    rife_reset_stats_fn reset_stats;
    uint64_t generated;
    uint64_t scene_bypass;
    uint64_t discontinuity_bypass;
    uint64_t cadence_bypass;
    uint64_t overload_bypass;
    uint64_t error_bypass;
    uint64_t attempts;
    uint64_t attempt_total_us;
    uint64_t attempt_max_us;
    uint64_t attempt_over_30ms;
    uint64_t attempt_over_33333us;
    uint64_t deadline_misses;
    uint64_t host_input_total_us;
    uint64_t host_input_max_us;
    uint64_t gpu_round_trip_total_us;
    uint64_t gpu_round_trip_max_us;
    uint64_t host_output_total_us;
    uint64_t host_output_max_us;
    uint32_t attempt_samples_us[PV_RIFE_TIMING_SAMPLE_CAPACITY];
    uint32_t gpu_round_trip_samples_us[PV_RIFE_TIMING_SAMPLE_CAPACITY];
    uint32_t timing_sample_count;
    uint32_t timing_sample_next;
    bool logged_processing_error;
    HANDLE worker;
    CRITICAL_SECTION worker_lock;
    CONDITION_VARIABLE worker_changed;
    bool worker_sync_initialized;
    bool worker_stop;
    bool worker_busy;
    bool discard_active;
    bool result_ready;
    bool midpoint_bypass;
    int task_head;
    int task_count;
    struct mp_image *task_current[PV_RIFE_TASK_CAPACITY];
    struct mp_image *task_next[PV_RIFE_TASK_CAPACITY];
    uint32_t task_flags[PV_RIFE_TASK_CAPACITY];
    double task_midpoint[PV_RIFE_TASK_CAPACITY];
    double active_midpoint;
    struct mp_image *result_output;
};

static int module_anchor;

static bool module_directory(wchar_t *path, size_t capacity)
{
    HMODULE self = NULL;
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                            GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                            (LPCWSTR)(const void *)&module_anchor, &self))
        return false;

    DWORD length = GetModuleFileNameW(self, path, (DWORD)capacity);
    if (!length || length >= capacity)
        return false;
    while (length > 0 && path[length - 1] != L'\\' && path[length - 1] != L'/')
        length--;
    if (!length)
        return false;
    path[length - 1] = L'\0';
    return true;
}

static bool append_path(wchar_t *path, size_t capacity, const wchar_t *suffix)
{
    size_t used = wcslen(path);
    size_t added = wcslen(suffix);
    if (used + 1 + added + 1 > capacity)
        return false;
    path[used++] = L'\\';
    memcpy(path + used, suffix, (added + 1) * sizeof(wchar_t));
    return true;
}

static bool wide_to_utf8(const wchar_t *input, char *output, size_t capacity)
{
    int written = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, input, -1,
                                      output, (int)capacity, NULL, NULL);
    return written > 0;
}

static FARPROC required_proc(HMODULE module, const char *name)
{
    return GetProcAddress(module, name);
}

static uint32_t timing_sample_us(uint64_t value)
{
    return value > UINT32_MAX ? UINT32_MAX : (uint32_t)value;
}

static int compare_timing_samples(const void *left, const void *right)
{
    uint32_t a = *(const uint32_t *)left;
    uint32_t b = *(const uint32_t *)right;
    return (a > b) - (a < b);
}

static uint32_t timing_percentile(uint32_t *samples, uint32_t count,
                                  uint32_t percentile)
{
    if (!count)
        return 0;
    qsort(samples, count, sizeof(samples[0]), compare_timing_samples);
    uint64_t rank = ((uint64_t)percentile * count + 99) / 100;
    rank = MPMAX(rank, 1);
    return samples[rank - 1];
}

static bool load_runtime(struct mp_filter *f)
{
    struct priv *p = f->priv;
    wchar_t base[32768];
    wchar_t dll_path[32768];
    wchar_t model_path[32768];
    char model_utf8[32768];
    char error[512] = {0};

    if (!module_directory(base, MP_ARRAY_SIZE(base))) {
        MP_ERR(f, "RIFE could not resolve the libmpv directory.\n");
        return false;
    }
    wcscpy_s(dll_path, MP_ARRAY_SIZE(dll_path), base);
    wcscpy_s(model_path, MP_ARRAY_SIZE(model_path), base);
    if (!append_path(dll_path, MP_ARRAY_SIZE(dll_path),
                     L"rife\\plainvideo_rife.dll") ||
        !append_path(model_path, MP_ARRAY_SIZE(model_path),
                     L"rife\\models\\rife-v4.25-lite_ensembleFalse") ||
        !wide_to_utf8(model_path, model_utf8, sizeof(model_utf8)))
    {
        MP_ERR(f, "RIFE runtime paths are too long or invalid.\n");
        return false;
    }

    p->runtime_module = LoadLibraryExW(dll_path, NULL,
        LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
    if (!p->runtime_module) {
        MP_ERR(f, "RIFE runtime is unavailable at the expected local path.\n");
        return false;
    }

    rife_abi_version_fn abi_version = (rife_abi_version_fn)
        required_proc(p->runtime_module, "plainvideo_rife_abi_version");
    rife_create_fn create = (rife_create_fn)
        required_proc(p->runtime_module, "plainvideo_rife_create");
    p->destroy = (rife_destroy_fn)
        required_proc(p->runtime_module, "plainvideo_rife_destroy");
    p->process = (rife_process_fn)
        required_proc(p->runtime_module, "plainvideo_rife_process");
    p->reset_stats = (rife_reset_stats_fn)
        required_proc(p->runtime_module, "plainvideo_rife_reset_stats");
    rife_device_name_fn device_name = (rife_device_name_fn)
        required_proc(p->runtime_module, "plainvideo_rife_get_device_name");
    if (!abi_version || !create || !p->destroy || !p->process ||
        !p->reset_stats || !device_name || abi_version() != PV_RIFE_ABI_VERSION)
    {
        MP_ERR(f, "RIFE runtime ABI does not match this libmpv build.\n");
        return false;
    }

    PlainVideoRifeConfig config = {
        .struct_size = sizeof(config),
        .width = 1920,
        .height = 1080,
        .gpu_index = p->opts->gpu_index,
        .inference_threads = 1,
        .deadline_us = p->opts->deadline_us,
        .max_queue_depth = 1,
        .overload_cooldown_frames = 2,
        .pipeline_mode = PV_RIFE_PIPELINE_PERSISTENT_VULKAN_STAGED,
    };
    int32_t status = create(&config, model_utf8, &p->runtime,
                            error, sizeof(error));
    if (status != PV_RIFE_OK || !p->runtime) {
        MP_ERR(f, "RIFE initialization failed: %s\n",
               error[0] ? error : "unknown error");
        return false;
    }

    char device[256] = {0};
    if (device_name(p->runtime, device, sizeof(device)) == PV_RIFE_OK)
        MP_INFO(f, "RIFE frame doubler initialized on %s.\n", device);
    else
        MP_INFO(f, "RIFE frame doubler initialized.\n");
    return true;
}

static bool scene_change(const struct mp_image *a, const struct mp_image *b,
                         int threshold)
{
    uint64_t total_difference = 0;
    uint64_t changed_samples = 0;
    uint64_t samples = 0;

    for (int y = 4; y < a->h; y += 8) {
        const uint8_t *row_a = a->planes[0] + (ptrdiff_t)a->stride[0] * y;
        const uint8_t *row_b = b->planes[0] + (ptrdiff_t)b->stride[0] * y;
        for (int x = 4; x < a->w; x += 8) {
            const uint8_t *pa = row_a + (ptrdiff_t)x * 4;
            const uint8_t *pb = row_b + (ptrdiff_t)x * 4;
            int difference = (abs((int)pa[0] - (int)pb[0]) +
                              abs((int)pa[1] - (int)pb[1]) +
                              abs((int)pa[2] - (int)pb[2])) / 3;
            total_difference += (uint64_t)difference;
            changed_samples += difference >= threshold;
            samples++;
        }
    }

    if (!samples)
        return false;
    double mean = total_difference / (double)samples;
    double changed_fraction = changed_samples / (double)samples;
    return mean >= threshold && changed_fraction >= 0.55;
}

static struct mp_image *source_output(struct mp_image *source)
{
    struct mp_image *out = mp_image_new_ref(source);
    if (out)
        out->pkt_duration = source->pkt_duration > 0.0
                          ? source->pkt_duration / 2.0 : source->pkt_duration;
    return out;
}

static struct mp_image *interpolated_output(struct mp_filter *f,
                                            struct mp_image *current,
                                            struct mp_image *next,
                                            uint32_t flags)
{
    struct priv *p = f->priv;
    struct mp_image *out = mp_image_alloc(IMGFMT_BGRA, current->w, current->h);
    if (!out)
        return NULL;
    mp_image_copy_attributes(out, current);
    double interval = next->pts - current->pts;
    out->pts = isfinite(interval) && interval > 0.0
             ? current->pts + interval / 2.0 : current->pts;
    out->pkt_duration = current->pkt_duration > 0.0
                      ? current->pkt_duration / 2.0 : current->pkt_duration;

    if (current->w != 1920 || current->h != 1080 ||
        next->w != 1920 || next->h != 1080 ||
        current->imgfmt != IMGFMT_BGRA || next->imgfmt != IMGFMT_BGRA ||
        current->stride[0] <= 0 || next->stride[0] <= 0 || out->stride[0] <= 0)
    {
        mp_image_copy(out, current);
        p->overload_bypass++;
        return out;
    }

    PlainVideoRifeRequest request = {
        .struct_size = sizeof(request),
        .frame0_bgra8 = current->planes[0],
        .frame0_stride_bytes = current->stride[0],
        .frame1_bgra8 = next->planes[0],
        .frame1_stride_bytes = next->stride[0],
        .output_bgra8 = out->planes[0],
        .output_stride_bytes = out->stride[0],
        .timestep = 0.5f,
        .flags = flags,
        .queue_depth = 0,
    };
    PlainVideoRifeResult result = {.struct_size = sizeof(result)};
    char error[512] = {0};
    int32_t status = p->process(p->runtime, &request, &result,
                                error, sizeof(error));
    p->attempts++;
    p->attempt_total_us += result.attempt_us;
    p->attempt_max_us = MPMAX(p->attempt_max_us, result.attempt_us);
    p->attempt_over_30ms += result.attempt_us > 30000;
    p->attempt_over_33333us += result.attempt_us > 33333;
    p->deadline_misses += result.deadline_exceeded != 0;
    p->host_input_total_us += result.host_input_prepare_us;
    p->host_input_max_us = MPMAX(p->host_input_max_us,
                                 result.host_input_prepare_us);
    p->gpu_round_trip_total_us += result.gpu_round_trip_us;
    p->gpu_round_trip_max_us = MPMAX(p->gpu_round_trip_max_us,
                                     result.gpu_round_trip_us);
    p->host_output_total_us += result.host_output_pack_us;
    p->host_output_max_us = MPMAX(p->host_output_max_us,
                                  result.host_output_pack_us);
    uint32_t timing_slot = p->timing_sample_next;
    p->attempt_samples_us[timing_slot] = timing_sample_us(result.attempt_us);
    p->gpu_round_trip_samples_us[timing_slot] =
        timing_sample_us(result.gpu_round_trip_us);
    p->timing_sample_next =
        (timing_slot + 1) % PV_RIFE_TIMING_SAMPLE_CAPACITY;
    p->timing_sample_count = MPMIN(p->timing_sample_count + 1,
                                   PV_RIFE_TIMING_SAMPLE_CAPACITY);
    if (status != PV_RIFE_OK) {
        mp_image_copy(out, current);
        p->error_bypass++;
        if (!p->logged_processing_error) {
            MP_WARN(f, "RIFE processing failed; source-frame fallback is active: %s\n",
                    error[0] ? error : "unknown error");
            p->logged_processing_error = true;
        }
        return out;
    }

    switch (result.status) {
    case PV_RIFE_STATUS_GENERATED: p->generated++; break;
    case PV_RIFE_STATUS_BYPASSED_SCENE_CHANGE: p->scene_bypass++; break;
    case PV_RIFE_STATUS_BYPASSED_DISCONTINUITY: p->discontinuity_bypass++; break;
    case PV_RIFE_STATUS_BYPASSED_OVERLOAD: p->overload_bypass++; break;
    case PV_RIFE_STATUS_BYPASSED_ERROR: p->error_bypass++; break;
    default:
        mp_image_copy(out, current);
        p->error_bypass++;
        break;
    }
    return out;
}

static DWORD WINAPI rife_worker(void *context)
{
    struct mp_filter *f = context;
    struct priv *p = f->priv;

    for (;;) {
        EnterCriticalSection(&p->worker_lock);
        while (!p->worker_stop && p->task_count == 0)
            SleepConditionVariableCS(&p->worker_changed, &p->worker_lock,
                                     INFINITE);
        if (p->worker_stop) {
            LeaveCriticalSection(&p->worker_lock);
            break;
        }

        int slot = p->task_head;
        struct mp_image *current = p->task_current[slot];
        struct mp_image *next = p->task_next[slot];
        uint32_t flags = p->task_flags[slot];
        p->active_midpoint = p->task_midpoint[slot];
        p->task_current[slot] = NULL;
        p->task_next[slot] = NULL;
        p->task_head = (p->task_head + 1) % PV_RIFE_TASK_CAPACITY;
        p->task_count--;
        p->worker_busy = true;
        WakeAllConditionVariable(&p->worker_changed);
        LeaveCriticalSection(&p->worker_lock);

        struct mp_image *out = interpolated_output(f, current, next, flags);
        talloc_free(current);
        talloc_free(next);

        EnterCriticalSection(&p->worker_lock);
        while (!p->worker_stop && !p->discard_active && p->result_ready)
            SleepConditionVariableCS(&p->worker_changed, &p->worker_lock,
                                     INFINITE);
        bool wake_filter = !p->worker_stop && !p->discard_active;
        if (wake_filter) {
            p->result_output = out;
            p->result_ready = true;
        } else {
            talloc_free(out);
        }
        p->discard_active = false;
        p->worker_busy = false;
        p->active_midpoint = 0.0;
        WakeAllConditionVariable(&p->worker_changed);
        LeaveCriticalSection(&p->worker_lock);

        if (wake_filter)
            mp_filter_wakeup(f);
    }
    return 0;
}

static bool same_pts(double a, double b)
{
    return isfinite(a) && isfinite(b) && fabs(a - b) < 0.0005;
}

static bool pair_is_scheduled_locked(struct priv *p, double midpoint)
{
    if (p->result_ready && p->result_output &&
        same_pts(p->result_output->pts, midpoint))
        return true;
    if (p->worker_busy && same_pts(p->active_midpoint, midpoint))
        return true;
    for (int n = 0; n < p->task_count; ++n) {
        int slot = (p->task_head + n) % PV_RIFE_TASK_CAPACITY;
        if (same_pts(p->task_midpoint[slot], midpoint))
            return true;
    }
    return false;
}

static bool schedule_interpolation(struct mp_filter *f,
                                   struct mp_image *current,
                                   struct mp_image *next,
                                   bool count_bypass)
{
    struct priv *p = f->priv;
    if (!current || !next || current->w != 1920 || current->h != 1080 ||
        next->w != 1920 || next->h != 1080 ||
        current->imgfmt != IMGFMT_BGRA || next->imgfmt != IMGFMT_BGRA ||
        current->stride[0] <= 0 || next->stride[0] <= 0)
    {
        p->overload_bypass += count_bypass;
        return false;
    }

    double interval = next->pts - current->pts;
    double midpoint = current->pts + interval / 2.0;
    if (!isfinite(current->pts) || !isfinite(next->pts) ||
        interval <= 0.0 || interval >= 1.0)
    {
        p->discontinuity_bypass += count_bypass;
        return false;
    }
    // The default fallback must never slow high-cadence media. The exact
    // 1080p target currently qualifies only source rates through 25 fps.
    // A higher ceiling is exposed only as an explicit experimental option so
    // 30->60 playback can be measured without changing normal activation.
    if (interval < 1.0 / p->opts->max_source_fps) {
        p->cadence_bypass += count_bypass;
        return false;
    }
    if (scene_change(current, next, p->opts->scene_threshold)) {
        p->scene_bypass += count_bypass;
        return false;
    }

    EnterCriticalSection(&p->worker_lock);
    bool already_scheduled = pair_is_scheduled_locked(p, midpoint);
    LeaveCriticalSection(&p->worker_lock);
    if (already_scheduled)
        return true;

    struct mp_image *task_current = mp_image_new_ref(current);
    struct mp_image *task_next = mp_image_new_ref(next);
    if (!task_current || !task_next) {
        talloc_free(task_current);
        talloc_free(task_next);
        p->error_bypass += count_bypass;
        return false;
    }

    EnterCriticalSection(&p->worker_lock);
    already_scheduled = pair_is_scheduled_locked(p, midpoint);
    bool available = !p->worker_stop && !already_scheduled &&
                     p->task_count < PV_RIFE_TASK_CAPACITY;
    if (available) {
        int slot = (p->task_head + p->task_count) % PV_RIFE_TASK_CAPACITY;
        p->task_current[slot] = task_current;
        p->task_next[slot] = task_next;
        p->task_flags[slot] = 0;
        p->task_midpoint[slot] = midpoint;
        p->task_count++;
        WakeConditionVariable(&p->worker_changed);
    }
    LeaveCriticalSection(&p->worker_lock);
    if (already_scheduled) {
        talloc_free(task_current);
        talloc_free(task_next);
        return true;
    }
    if (!available) {
        talloc_free(task_current);
        talloc_free(task_next);
        p->overload_bypass += count_bypass;
    }
    return available;
}

static struct mp_image *take_interpolated_result(struct priv *p,
                                                  double expected_pts,
                                                  bool *waiting)
{
    struct mp_image *out = NULL;
    EnterCriticalSection(&p->worker_lock);
    if (p->result_ready && p->result_output &&
        same_pts(p->result_output->pts, expected_pts)) {
        out = p->result_output;
        p->result_output = NULL;
        p->result_ready = false;
        WakeAllConditionVariable(&p->worker_changed);
    }
    *waiting = pair_is_scheduled_locked(p, expected_pts);
    LeaveCriticalSection(&p->worker_lock);
    return out;
}

static void rife_process_filter(struct mp_filter *f)
{
    struct priv *p = f->priv;
    mp_refqueue_execute_reinit(p->queue);
    if (!mp_refqueue_can_output(p->queue))
        return;

    struct mp_image *current = mp_refqueue_get(p->queue, 0);
    struct mp_image *next = mp_refqueue_get(p->queue, 1);
    struct mp_image *next2 = mp_refqueue_get(p->queue, 2);
    struct mp_image *out = NULL;
    if (!mp_refqueue_is_second_field(p->queue)) {
        p->midpoint_bypass = !schedule_interpolation(f, current, next, true);
        // Keep one pair queued ahead. The worker can then use almost the full
        // source-frame interval instead of starting each midpoint only after
        // its preceding source frame has already been presented.
        (void)schedule_interpolation(f, next, next2, false);
        out = source_output(current);
    } else if (current && next) {
        bool waiting = false;
        out = take_interpolated_result(p, current->pts, &waiting);
        if (!out && waiting && !p->midpoint_bypass)
            return;
        if (!out)
            out = source_output(current);
    } else {
        out = source_output(current);
    }
    mp_refqueue_write_out_pin(p->queue, out);
}

static void rife_reset(struct mp_filter *f)
{
    struct priv *p = f->priv;
    if (p->worker_sync_initialized) {
        EnterCriticalSection(&p->worker_lock);
        talloc_free(p->result_output);
        p->result_output = NULL;
        p->result_ready = false;
        for (int n = 0; n < p->task_count; ++n) {
            int slot = (p->task_head + n) % PV_RIFE_TASK_CAPACITY;
            talloc_free(p->task_current[slot]);
            talloc_free(p->task_next[slot]);
            p->task_current[slot] = NULL;
            p->task_next[slot] = NULL;
        }
        p->task_head = 0;
        p->task_count = 0;
        p->discard_active = p->worker_busy;
        WakeAllConditionVariable(&p->worker_changed);
        while (p->worker_busy)
            SleepConditionVariableCS(&p->worker_changed, &p->worker_lock,
                                     INFINITE);
        p->midpoint_bypass = true;
        LeaveCriticalSection(&p->worker_lock);
    }
    mp_refqueue_flush(p->queue);
    if (p->runtime && p->reset_stats)
        p->reset_stats(p->runtime);
}

static void rife_destroy_filter(struct mp_filter *f)
{
    struct priv *p = f->priv;
    if (p->worker_sync_initialized) {
        EnterCriticalSection(&p->worker_lock);
        p->worker_stop = true;
        for (int n = 0; n < p->task_count; ++n) {
            int slot = (p->task_head + n) % PV_RIFE_TASK_CAPACITY;
            talloc_free(p->task_current[slot]);
            talloc_free(p->task_next[slot]);
            p->task_current[slot] = NULL;
            p->task_next[slot] = NULL;
        }
        p->task_count = 0;
        WakeAllConditionVariable(&p->worker_changed);
        LeaveCriticalSection(&p->worker_lock);
        if (p->worker) {
            WaitForSingleObject(p->worker, INFINITE);
            CloseHandle(p->worker);
        }
        talloc_free(p->result_output);
        p->result_output = NULL;
        DeleteCriticalSection(&p->worker_lock);
        p->worker_sync_initialized = false;
    }
    // mp_refqueue owns an autoconvert child filter. Release it from this
    // callback, like mpv's built-in refqueue filters do, so the generic filter
    // destructor does not tear down that child first and leave the queue with
    // a dangling filter pointer.
    talloc_free(p->queue);
    p->queue = NULL;
    MP_INFO(f, "RIFE session: generated=%llu scene=%llu discontinuity=%llu "
               "cadence=%llu overload=%llu error=%llu.\n",
            (unsigned long long)p->generated,
            (unsigned long long)p->scene_bypass,
            (unsigned long long)p->discontinuity_bypass,
            (unsigned long long)p->cadence_bypass,
            (unsigned long long)p->overload_bypass,
            (unsigned long long)p->error_bypass);
    if (p->attempts) {
        uint32_t attempt_p50_samples[PV_RIFE_TIMING_SAMPLE_CAPACITY];
        uint32_t attempt_p95_samples[PV_RIFE_TIMING_SAMPLE_CAPACITY];
        uint32_t attempt_p99_samples[PV_RIFE_TIMING_SAMPLE_CAPACITY];
        uint32_t gpu_p95_samples[PV_RIFE_TIMING_SAMPLE_CAPACITY];
        uint32_t gpu_p99_samples[PV_RIFE_TIMING_SAMPLE_CAPACITY];
        size_t sample_bytes = p->timing_sample_count * sizeof(uint32_t);
        memcpy(attempt_p50_samples, p->attempt_samples_us, sample_bytes);
        memcpy(attempt_p95_samples, p->attempt_samples_us, sample_bytes);
        memcpy(attempt_p99_samples, p->attempt_samples_us, sample_bytes);
        memcpy(gpu_p95_samples, p->gpu_round_trip_samples_us, sample_bytes);
        memcpy(gpu_p99_samples, p->gpu_round_trip_samples_us, sample_bytes);
        uint32_t attempt_p50 = timing_percentile(
            attempt_p50_samples, p->timing_sample_count, 50);
        uint32_t attempt_p95 = timing_percentile(
            attempt_p95_samples, p->timing_sample_count, 95);
        uint32_t attempt_p99 = timing_percentile(
            attempt_p99_samples, p->timing_sample_count, 99);
        uint32_t gpu_p95 = timing_percentile(
            gpu_p95_samples, p->timing_sample_count, 95);
        uint32_t gpu_p99 = timing_percentile(
            gpu_p99_samples, p->timing_sample_count, 99);
        MP_INFO(f, "RIFE timing: attempts=%llu mean=%llu us p50=%u us "
                   "p95=%u us p99=%u us max=%llu us over-30ms=%llu "
                   "over-33.33ms=%llu deadline-misses=%llu samples=%u.\n",
                (unsigned long long)p->attempts,
                (unsigned long long)(p->attempt_total_us / p->attempts),
                attempt_p50,
                attempt_p95,
                attempt_p99,
                (unsigned long long)p->attempt_max_us,
                (unsigned long long)p->attempt_over_30ms,
                (unsigned long long)p->attempt_over_33333us,
                (unsigned long long)p->deadline_misses,
                p->timing_sample_count);
        MP_INFO(f, "RIFE stages: host-input-mean=%llu us "
                   "host-input-max=%llu us gpu-mean=%llu us gpu-p95=%u us "
                   "gpu-p99=%u us gpu-max=%llu us host-output-mean=%llu us "
                   "host-output-max=%llu us.\n",
                (unsigned long long)(p->host_input_total_us / p->attempts),
                (unsigned long long)p->host_input_max_us,
                (unsigned long long)(p->gpu_round_trip_total_us / p->attempts),
                gpu_p95,
                gpu_p99,
                (unsigned long long)p->gpu_round_trip_max_us,
                (unsigned long long)(p->host_output_total_us / p->attempts),
                (unsigned long long)p->host_output_max_us);
    }
    if (p->runtime && p->destroy) {
        MP_INFO(f, "RIFE native context teardown starting.\n");
        p->destroy(p->runtime);
        MP_INFO(f, "RIFE native context teardown completed.\n");
    }
    p->runtime = NULL;
    if (p->runtime_module) {
        MP_INFO(f, "RIFE runtime unload starting.\n");
        FreeLibrary(p->runtime_module);
        MP_INFO(f, "RIFE runtime unload completed.\n");
    }
    p->runtime_module = NULL;
}

static const struct mp_filter_info rife_filter = {
    .name = "plainvideo-rife",
    .process = rife_process_filter,
    .reset = rife_reset,
    .destroy = rife_destroy_filter,
    .priv_size = sizeof(struct priv),
};

static struct mp_filter *rife_create_filter(struct mp_filter *parent,
                                            void *options)
{
    struct mp_filter *f = mp_filter_create(parent, &rife_filter);
    if (!f) {
        talloc_free(options);
        return NULL;
    }
    mp_filter_add_pin(f, MP_PIN_IN, "in");
    mp_filter_add_pin(f, MP_PIN_OUT, "out");

    struct priv *p = f->priv;
    p->opts = talloc_steal(p, options);
    p->queue = mp_refqueue_alloc(f);
    mp_refqueue_add_in_format(p->queue, IMGFMT_BGRA, 0);
    mp_refqueue_set_refs(p->queue, 0, 2);
    mp_refqueue_set_mode(p->queue, MP_MODE_DEINT | MP_MODE_OUTPUT_FIELDS);

    if (!load_runtime(f)) {
        talloc_free(f);
        return NULL;
    }
    InitializeCriticalSection(&p->worker_lock);
    InitializeConditionVariable(&p->worker_changed);
    p->worker_sync_initialized = true;
    p->midpoint_bypass = true;
    p->worker = CreateThread(NULL, 0, rife_worker, f, 0, NULL);
    if (!p->worker) {
        MP_ERR(f, "RIFE could not start its interpolation worker.\n");
        talloc_free(f);
        return NULL;
    }
    return f;
}

#define OPT_BASE_STRUCT struct rife_opts
static const struct m_option rife_opts_fields[] = {
    {"gpu-index", OPT_INT(gpu_index), M_RANGE(0, 15)},
    {"deadline-us", OPT_INT(deadline_us), M_RANGE(1000, 100000)},
    {"scene-threshold", OPT_INT(scene_threshold), M_RANGE(10, 100)},
    {"max-source-fps", OPT_DOUBLE(max_source_fps), M_RANGE(23.0, 31.0)},
    {0}
};

static const struct rife_opts rife_opts_defaults = {
    .gpu_index = 0,
    .deadline_us = 33000,
    .scene_threshold = 38,
    .max_source_fps = 25.5,
};

const struct mp_user_filter_entry vf_plainvideo_rife = {
    .desc = {
        .description = "PlainVideo RIFE 2x frame doubler (experimental)",
        .name = "plainvideo-rife",
        .priv_size = sizeof(OPT_BASE_STRUCT),
        .priv_defaults = &rife_opts_defaults,
        .options = rife_opts_fields,
    },
    .create = rife_create_filter,
};
