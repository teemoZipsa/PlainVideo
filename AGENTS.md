# Agent Working Rules

## Product Identity Lock

- Keep the default playback surface borderless and content-first.
- Do not add permanently visible controls merely to expose a new feature.
- Prefer progressive disclosure: obvious playback controls first, contextual features second, advanced diagnostics last.
- Do not describe display-resample frame timing as AI frame generation.
- Do not claim a format, HDR path, hardware decoder, or frame-interpolation mode without evidence from the exact shipped build.
- Treat the portable Windows artifact as a first-class release output.

## GitHub Actions Cost Lock

- Do not add, enable, dispatch, rerun, or broaden GitHub Actions workflows without the user's explicit approval.
- Do not use a commit, push, or pull request merely to test remote CI. Run the repository's checks locally first.
- For private repositories, keep GitHub Actions disabled in repository settings. If it is explicitly re-enabled, workflows must remain manual-only (`workflow_dispatch`) unless the user approves otherwise.
- Existing automatic workflows in public repositories may remain only when they provide a real deployed service. Do not expand them without approval.
- Prefer an approved self-hosted runner when remote automation is explicitly required.

## Dependency and Release Accuracy

- Keep third-party playback, codec, model, and runtime licenses explicit and reproducible.
- A local build, uploaded package, submitted package, certified package, and publicly available release are different states; report the exact verified state.
- Never ship experimental frame interpolation as an unconditional default. Preserve a reliable source-frame fallback.
