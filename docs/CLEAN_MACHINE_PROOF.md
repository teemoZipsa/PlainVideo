# Clean Windows Sandbox proof

Status: **executed and verified on Windows 11 Enterprise 10.0.26100 x64 Windows Sandbox; candidate-not-release-approved.**

This harness is for the current `candidate-not-release-approved` shared-libmpv
portable candidate. It deliberately separates a clean-machine playback proof
from legal/source closure, a Windows-version support claim, and release
approval.

The latest run completed default sidecar loading, the portable runtime
closure, all 10 generated format rows, playback recovery, and the Quick
hardware/software soak. Its module snapshot observed `d3d11.dll`, `d3d9.dll`,
`dxva2.dll`, and `dxgi.dll` from the Sandbox system directory. The exact input
manifest and evidence remain ignored local artifacts; this outcome is not a
Windows 10 minimum-version proof or release approval.

## What the harness does

`prepare-clean-machine-proof.ps1` copies only the candidate portable build,
the generated playback fixtures, the two smoke files, and the four existing
verification scripts into an ignored staging directory. It produces an input
hash manifest and a Windows Sandbox `.wsb` file, but it does **not** start
Windows Sandbox.

The generated Sandbox configuration has two mapped folders:

| Sandbox path | Host mapping | Access |
| --- | --- | --- |
| `C:\PlainVideoInput` | staging `input` directory | read-only |
| `C:\PlainVideoEvidence` | staging `evidence` directory | writable |

Networking, clipboard redirection, audio input, and video input are disabled.
vGPU is enabled because the existing candidate render path needs a graphics
device. The runner first validates and copies the read-only input to local
`C:\PlainVideoProof`; all verification writes occur only in that local copy.

The local runner records the Sandbox OS and video-adapter snapshot, makes one
default sidecar-load run without `PLAINVIDEO_ROOT` or
`PLAINVIDEO_LIBMPV_PATH`, records its observed loaded modules, then runs:

- `verify-mpv-runtime.ps1` against the copied portable root;
- the complete format matrix with `-RequireAllRows`;
- playback-recovery verification; and
- the existing `Quick` hardware/software playback soak.

Its fixture evidence is rebased from the host staging path to the local
Sandbox copy before the matrix begins. Fixture bytes and SHA-256 checks remain
unchanged. Evidence is copied back only after the suite has written its local
summary, including when an individual verification fails.

## Prepare the proof

From a trusted checkout after the exact candidate portable build and fixture
generation are complete:

```powershell
$stage = .\scripts\prepare-clean-machine-proof.ps1
$stage.sandboxConfig
```

The default candidate is
`.runtime\portable\PlainVideo-lgpl-candidate`. The preparation host uses
`ffprobe` only to measure the copied primary smoke fixture so that the Sandbox
does not need a developer tool. If that host tool is intentionally unavailable,
provide an already measured duration:

```powershell
$stage = .\scripts\prepare-clean-machine-proof.ps1 `
  -PrimaryDurationSeconds 30
```

Review the generated `stage-summary.json`, `clean-machine-input.json`, and
`.wsb` path. Start the `.wsb` manually only after that review. The generated
logon command invokes the runner automatically; do not edit the mapped input
after its manifest is created.

On completion, examine the host stage's `evidence\result-*` directory. The
top-level `clean-machine\clean-machine-proof.json` names every verifier,
contains the platform snapshot location, and keeps the result
`candidate-not-release-approved` even if every technical check passes.

## Interpretation and remaining gates

A successful Sandbox run proves the exact staged bytes can complete this
bounded test on that fresh Sandbox image and its virtual GPU. It does not
prove a Windows 10 1703 machine, every later Windows version, every dynamic
loader branch, all hardware decoder paths, or any customer GPU driver.

It also does not close the separate release gates:

- transitive source and license retention, LGPL replacement/relinking review,
  codec rights, and Store terms;
- the explicit target-OS and dynamic-load compatibility review; and
- an authorized legal disposition that changes the candidate state.

Keep any failed Sandbox evidence. A failure is a result to diagnose, not a
reason to silently substitute host-only proof.
