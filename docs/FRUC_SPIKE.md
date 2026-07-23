# NVIDIA FRUC spike

Date: 2026-07-22

Status: official NVIDIA Optical Flow SDK 5.0.7 downloaded, stock sample built,
and native D3D11/CUDA execution measured; output quality gate failed

Release state: no FRUC binary, CUDA runtime, or FRUC product option is included
in PlainVideo

## Why this is the second candidate

NVIDIA's FRUC library uses the hardware Optical Flow Accelerator plus CUDA to
interpolate a frame between two consecutive inputs. The official library
supports NV12 and ARGB surfaces, Windows 10 or newer, and NVIDIA Turing or newer
GPUs. Its D3D11 path can share textures with the library, which is a better
architectural fit for 30-to-60 playback than PlainVideo's current RIFE
host-BGRA8 round trip.

Official programming flow:

1. securely load `NvOFFRUC.dll` and resolve the five `NvOFFRUC` entry points;
2. create a FRUC handle for fixed dimensions, surface format, and D3D11 or CUDA
   resource type;
3. create and register synchronized input/output resources;
4. submit each new source frame once and request the midpoint timestamp;
5. inspect the repetition flag, interleave valid output, and retain the source
   frame when quality or processing fails;
6. unregister resources and destroy the handle after all calls return.

The implementation should use D3D11 NV12 textures first, keyed mutex or
`ID3D11Fence` synchronization as required by the SDK, and the same queued mpv
filter policy proven by the RIFE experiment. It must be a separate optional
filter, never a replacement for the source path.

## Current machine preflight

Command:

```powershell
.\scripts\check-fruc-prerequisites.ps1
```

Observed machine:

- NVIDIA GeForce RTX 5070;
- NVIDIA display driver 610.52;
- compute capability reported as 12.0;
- exact package files `NvOFFRUC.dll` and `NvOFFRUC.h` found;
- no CUDA Toolkit compiler (`nvcc`) found;
- Visual Studio 2022 Build Tools CMake and MSVC compiler found;
- the stock Windows sample builds without `nvcc` by using the package's bundled
  CUDA header/runtime and loading the installed NVIDIA driver API dynamically;
- the existing RIFE Vulkan runtime is unrelated and cannot substitute for the
  FRUC SDK.

The GPU and driver exceed NVIDIA's documented Turing/driver baseline. The exact
5.0.7 DLL is NVIDIA-signed and its create/register/process/unregister/destroy
flow completes on this machine, but that alone does not prove usable output.

## Download and license gate

The current official download is NVIDIA Optical Flow SDK 5.0. NVIDIA states
that the SDK is free for commercial and educational applications, but download
requires NVIDIA Developer Program membership and clicking `Accept & Download`
confirms acceptance of NVIDIA's SDK agreement. PlainVideo must not automate
that legal acceptance or redistribute `NvOFFRUC.dll` until the user accepts the
terms and the redistribution clauses are reviewed against the intended
portable/Store package.

## Native execution result

The downloaded ZIP is 239,049,440 bytes with SHA-256
`89b0923adc6f34fbe86e63cc17d5db452e34b945c03ba90d8e09bd1a0158e917`.
The x64 `NvOFFRUC.dll` is signed by NVIDIA and has SHA-256
`5a0b6701d30709e25e7e5b92ca46b18aab1459160cecd4f629872369d85c8b0a`.

The unchanged official sample built with Visual Studio 2022 and successfully
called the five exports. Cross-checks used 1920x1080 NV12 and ARGB input plus
D3D11 and CUDA `cuDevicePtr` allocations. Every 24-frame case reported 23
repeated frames. A separate 48-frame real-video run reported 47 repeated frames
in both D3D11 and CUDA paths. Because the first call returns a source frame,
these runs produced zero usable midpoint frames.

Measured process averages were 4.19 ms for the 48-frame D3D11 real-video case
and 4.29 ms for CUDA, but those numbers represent repeated-source fallback, not
successful frame interpolation. `activationEligible` and `releaseAllowed`
therefore remain false.

Reproducible verifier:

```powershell
.\scripts\check-fruc-prerequisites.ps1 -SdkRoot <extracted-sdk-root>
.\scripts\verify-fruc-spike.ps1 -SdkRoot <extracted-sdk-root>
```

Latest automated evidence:
`.runtime/fruc-spike/evidence/20260722-231959-475/summary.json`.

| Resource path | Calls | Repeated | Usable midpoints | Average process | Quality gate |
| --- | ---: | ---: | ---: | ---: | --- |
| D3D11 NV12 | 24 | 23 | 0 / 23 | 4.549 ms | Fail |
| CUDA cuDevicePtr NV12 | 24 | 23 | 0 / 23 | 4.469 ms | Fail |

## Next decision

Do not integrate this DLL into PlainVideo while all candidate midpoints are
rejected. A later slice may:

- rerun the same verifier after a newer NVIDIA FRUC SDK or driver is available;
- ask NVIDIA whether Optical Flow SDK 5.0 FRUC supports Blackwell RTX 50-series;
- integrate only after non-repeated midpoint output, clean seek, scene-cut,
  A/V sync, shutdown, and source-fallback evidence;
- keep RIFE and FRUC mutually exclusive and disabled by default.

Official references:

- <https://developer.nvidia.com/opticalflow/download>
- <https://docs.nvidia.com/video-technologies/optical-flow-sdk/nvfruc-programming-guide/index.html>
