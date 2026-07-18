# Microsoft Store release plan

Date: 2026-07-19
Status: planning; no Partner Center identity, package, submission, certification, or public Store release exists

## Product decision

PlainVideo is planned as a free Microsoft Store app and a first-class portable Windows app built from the same locked source and playback runtime.

- Product: borderless, content-first local video player
- Pricing: free
- Advertising, accounts, telemetry, and in-app purchases: none
- Initial architecture: x64
- Store device family: `Windows.Desktop`
- Store languages: separate `en-US` and `ko-KR` listings and screenshots
- Preferred Store path: packaged Win32 app distributed as MSIX
- Direct release path: portable ZIP/directory remains a separate first-class artifact

Microsoft currently accepts both packaged MSIX Win32 apps and externally hosted MSI/EXE installers. PlainVideo chooses MSIX because the Store can host and sign it, manage updates, provide package identity, register file associations declaratively, and uninstall cleanly. The MSI/EXE listing route would require a stable versioned HTTPS installer, publisher signing, silent offline installation, and publisher-managed updates.

Official references:

- [How to distribute a Win32 app through Microsoft Store](https://learn.microsoft.com/windows/apps/distribute-through-store/how-to-distribute-your-win32-app-through-microsoft-store)
- [Packaging overview](https://learn.microsoft.com/windows/apps/package-and-deploy/packaging/)
- [Upload MSIX app packages](https://learn.microsoft.com/windows/apps/publish/publish-your-app/msix/upload-app-packages)
- [Microsoft Store policies](https://learn.microsoft.com/windows/apps/publish/store-policies)

## Release gate 0: distributable playback runtime

This is the current blocking gate. The pinned `shinchiro/mpv-winbuild-cmake` binary is conservatively treated as GPL-2.0-or-later and is explicitly marked developer-only. It must not enter an MSIX or public portable release yet.

Choose and document one legally reviewed route:

1. Preferred: reproduce an LGPL-compatible mpv/FFmpeg/libplacebo/libass build with GPL-only components disabled, dynamic linking preserved, exact build options checked in, and all corresponding notices/source links shipped.
2. Alternative: distribute the combined work under a GPL-compatible release model with complete corresponding source and Store-terms review.

For either route, lock the exact upstream revisions, compiler, build flags, enabled demuxers/decoders/protocols, license for every binary component, SHA-256 values, source archive/offer, and patent-sensitive codec review. Generate the advertised format matrix from that exact runtime. A public GitHub repository does not by itself satisfy all binary redistribution obligations.

Exit criteria:

- reproducible runtime build from checked-in instructions;
- complete machine-readable component/license inventory;
- reviewed notices and corresponding-source delivery plan;
- exact runtime passes MP4, MKV, external SRT, hardware decode, and software fallback tests;
- legal disposition changes from `developer-only` to an explicitly approved release profile.

## Release gate 1: Store identity and native app metadata

Locate or reserve `PlainVideo` in Partner Center before freezing package identity. The current Partner Center reservation state has not been checked. Do not invent `Identity Name` or `Publisher`; copy both values exactly from Partner Center.

Add native release metadata:

- Windows application icon and version resources in `plainvideo.exe`;
- stable product/publisher/company fields;
- four-part Store package version mapped from the Cargo version;
- `Package.appxmanifest` for a full-trust desktop executable;
- `runFullTrust` only as required for the packaged Win32 process;
- `Windows.Desktop` target family and a minimum OS version chosen from actual Windows 10/11 tests;
- package-safe writable settings path and packaged/unpackaged migration test.

The first Store candidate remains x64. ARM64 is a later package only after an ARM64 libmpv runtime and real ARM64 hardware validation exist.

## Release gate 2: MSIX build and Windows integration

Create a deterministic local packaging flow under `packaging/msix` and `scripts` that emits only ignored artifacts under `.runtime` or `artifacts`.

Required package contents:

- `plainvideo.exe`;
- approved `libmpv-2.dll` and every required runtime DLL;
- `assets/mpv` configuration and scripts;
- app logos/tiles at all manifest-required sizes;
- original license, third-party notices, runtime provenance, and source links;
- `Package.appxmanifest` generated from Partner Center identity and the locked version.

File associations use manifest `windows.fileTypeAssociation` declarations and must never silently take over user defaults. Start with extensions proven by the exact release build and expand only after the generated format matrix passes. MP4, MKV, and external SRT are the current evidence baseline, not a final compatibility claim.

Packaging outputs:

- developer-signed `.msix` for local sideload tests;
- Store upload artifact accepted by Partner Center;
- package content manifest with size and SHA-256 for every file;
- matching portable artifact built from the same clean commit and runtime.

## Release gate 3: product readiness

Before packaging is called release-ready:

- implement stable open-with/file activation for every declared extension;
- preserve settings across Store updates and define portable-to-Store migration behavior;
- add an About surface containing version, licenses, source, privacy, and support links without adding permanent playback chrome;
- add a plain-language playback error surface and software-decoder fallback evidence;
- test clean install, update, uninstall, reinstall, file activation, drag/drop, subtitle selection, multi-monitor placement, 200% text, keyboard-only use, and screen-reader names;
- complete a longer playback/replacement/resize soak and a generated format matrix;
- remove stale documentation that describes obsolete controls.

The minimum Store release must be useful at first launch, accurately represented, testable without private accounts, and free of unsupported codec/HDR/hardware claims.

## Release gate 4: local certification and provenance

Every candidate is rebuilt from its final clean source commit. Record the commit, package version, package hash, runtime hash, tool versions, and test results before Partner Center upload.

Required local gates:

1. Rust formatting, tests, Clippy, and release build.
2. Deterministic runtime/license inventory checks.
3. Defender scan of staged files and final package.
4. Windows App Certification Kit against the installed candidate.
5. Developer-signed install/playback/file-association/update/uninstall on the host.
6. Fresh Windows Sandbox or clean VM install and first-frame proof.
7. MP4/MKV/external-SRT smoke from the installed package.
8. Korean and English UI/listing screenshot verification.
9. Exact package content/hash/provenance report.

GitHub Actions remain out of scope unless explicitly approved. Store validation is local-first and must not be triggered by a commit merely to consume remote CI.

## Release gate 5: Store presence

Create public pages before submission:

- privacy policy: local-file behavior, no telemetry/account/ads, and any future network behavior stated accurately;
- support page: supported Windows versions, shortcuts, subtitle help, logs, issue-report route, and license links;
- source/license page pointing to the public GitHub repository and exact release tag/source archive.

Partner Center work:

- reserve the product name and copy the exact Store identity into packaging configuration;
- choose the most accurate video-player category available in the live dashboard;
- complete IARC age-rating questions accurately;
- configure public audience, markets, discoverability, and free pricing;
- upload the final package only after local gates pass;
- maintain separate `en-US` and `ko-KR` listings;
- include at least four rights-cleared screenshots per locale;
- provide certification notes explaining local media selection, file associations, shortcuts, subtitle testing, and the absence of an account;
- use a private package flight before general availability when the account supports it.

Submission, certification, and publication are distinct states. Update `STORE_RELEASE_STATE.json` only from current Partner Center evidence and never describe a validated or submitted package as publicly available.

## Milestones

| Milestone | Outcome | Current state |
|---|---|---|
| S0 — Store plan | Distribution choice, gates, bilingual listing draft, state file | Complete |
| S1 — Runtime closure | Reproducible distributable libmpv/FFmpeg profile | Blocked by license/build inventory |
| S2 — Package proof | Partner identity, assets, manifest, x64 developer MSIX | Not started |
| S3 — Installed-app proof | WACK, host/Sandbox, activation/update/uninstall | Not started |
| S4 — Listing readiness | Privacy/support/source pages and localized captures | Not started |
| S5 — Partner Center flight | Exact package uploaded to a limited audience | Not started |
| S6 — Public release | Certification passed and availability verified independently | Not started |

## Immediate next work

1. Build and inventory an LGPL-compatible libmpv/FFmpeg candidate.
2. Check whether `PlainVideo` is already reserved in Partner Center; reserve it if needed and record the exact identity values.
3. Create original app icon/logo assets and the MSIX manifest template.
4. Add deterministic Store-package build, install, WACK, and uninstall scripts.
5. Publish privacy/support/source pages and produce separate Korean/English listing media.
