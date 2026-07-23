#!/usr/bin/env bash
set -euo pipefail

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

: "${PLAINVIDEO_REPO_ROOT:?PLAINVIDEO_REPO_ROOT is required}"
: "${PLAINVIDEO_BUILD_ROOT:?PLAINVIDEO_BUILD_ROOT is required}"
: "${PLAINVIDEO_JOBS:?PLAINVIDEO_JOBS is required}"
[[ "${MSYSTEM:-}" == 'CLANG64' ]] || fail 'Run inside the MSYS2 CLANG64 environment.'
[[ "$PLAINVIDEO_JOBS" =~ ^[1-9][0-9]*$ ]] || fail "Invalid PLAINVIDEO_JOBS: $PLAINVIDEO_JOBS"

repo_root="$(cygpath -u "$PLAINVIDEO_REPO_ROOT")"
build_root="$(cygpath -u "$PLAINVIDEO_BUILD_ROOT")"
runtime_flavor="${PLAINVIDEO_RUNTIME_FLAVOR:-lgpl-libmpv}"
[[ "$runtime_flavor" =~ ^[A-Za-z0-9._-]+$ ]] || fail "Unsafe runtime flavor: $runtime_flavor"
profile="$repo_root/third_party/lgpl-libmpv-profile.json"
output_root="$repo_root/.runtime/$runtime_flavor"
runtime_root="$output_root/runtime"
evidence_root="$output_root/evidence"
licenses_root="$output_root/licenses"
source_root="$build_root/sources"

[[ -f "$profile" ]] || fail "Missing profile: $profile"
for command in clang git make meson nasm pkg-config python; do
    command -v "$command" >/dev/null 2>&1 || fail "Missing CLANG64 command: $command"
done

profile_value() {
    python - "$profile" "$1" <<'PY'
import json
import sys
value = json.load(open(sys.argv[1], encoding='utf-8'))
for part in sys.argv[2].split('.'):
    value = value[part]
if isinstance(value, (dict, list)):
    raise SystemExit(f'profile value must be scalar: {sys.argv[2]}')
print(value)
PY
}

source_field() {
    python - "$profile" "$1" "$2" <<'PY'
import json
import sys
for source in json.load(open(sys.argv[1], encoding='utf-8'))['sources']:
    if source['name'] == sys.argv[2]:
        print(source[sys.argv[3]])
        break
else:
    raise SystemExit(f'source not found: {sys.argv[2]}')
PY
}

profile_array() {
    python - "$profile" "$1" <<'PY'
import json
import sys
for item in json.load(open(sys.argv[1], encoding='utf-8'))[sys.argv[2]]:
    print(item)
PY
}

python - "$profile" <<'PY'
import json
import sys
profile = json.load(open(sys.argv[1], encoding='utf-8'))
assert profile['schemaVersion'] == 1
assert profile['status'] == 'candidate-not-release-approved'
assert profile['architecture'] == 'x86_64'
PY

profile_sha256="$(sha256sum "$profile" | awk '{print $1}')"
default_build_id="$(date -u +%Y%m%d-%H%M%S)-${profile_sha256:0:12}"
build_id="${PLAINVIDEO_BUILD_ID:-$default_build_id}"
[[ "$build_id" =~ ^[A-Za-z0-9._-]+$ ]] || fail "Unsafe PLAINVIDEO_BUILD_ID: $build_id"
prefix="$build_root/prefix-$build_id"
build_output_root="$build_root/build-$build_id"
[[ ! -e "$prefix" ]] || fail "Refusing to reuse an existing build prefix: $prefix"
[[ ! -e "$build_output_root" ]] || fail "Refusing to reuse an existing build directory: $build_output_root"

checkout_source() {
    local name="$1" repo tag commit directory actual
    repo="$(source_field "$name" repository)"
    tag="$(source_field "$name" tag)"
    commit="$(source_field "$name" commit)"
    directory="$source_root/$name"

    if [[ -e "$directory" && ! -d "$directory/.git" ]]; then
        fail "Source cache path is not a Git checkout: $directory"
    fi
    if [[ ! -d "$directory/.git" ]]; then
        git clone --no-checkout "$repo" "$directory"
    fi
    git -C "$directory" fetch --force --tags origin "refs/tags/$tag:refs/tags/$tag"
    git -C "$directory" checkout --detach "$tag"
    actual="$(git -C "$directory" rev-parse HEAD)"
    [[ "$actual" == "$commit" ]] || fail "$name resolved to $actual instead of pinned $commit"
    git -C "$directory" submodule sync --recursive
    git -C "$directory" submodule update --init --recursive
    [[ -z "$(git -C "$directory" status --porcelain)" ]] || fail "$name source cache is dirty: $directory"

    mkdir -p "$evidence_root/sources"
    {
        printf 'name=%s\nrepository=%s\ntag=%s\ncommit=%s\n' "$name" "$repo" "$tag" "$actual"
        git -C "$directory" show -s --format='committer=%cI%nsubject=%s' HEAD
        git -C "$directory" submodule status --recursive
    } > "$evidence_root/sources/$name.txt"
}

configure_meson() {
    local source="$1" build="$2" arguments_file="$3"
    local -a arguments=()
    mapfile -t arguments < <(tr -d '\r' < "$arguments_file")
    if [[ -f "$build/meson-private/coredata.dat" ]]; then
        meson setup --wipe "$build" "$source" --prefix="$prefix" --libdir=lib --buildtype=release --wrap-mode=nodownload "${arguments[@]}"
    else
        meson setup "$build" "$source" --prefix="$prefix" --libdir=lib --buildtype=release --wrap-mode=nodownload "${arguments[@]}"
    fi
}

mkdir -p "$source_root" "$build_output_root"
if [[ -e "$output_root" && -n "$(find "$output_root" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    fail "Refusing to overwrite an existing candidate output: $output_root"
fi
mkdir -p "$prefix" "$runtime_root" "$evidence_root" "$licenses_root"

export PATH="$prefix/bin:/clang64/bin:$PATH"
export PKG_CONFIG_PATH="$prefix/lib/pkgconfig:/clang64/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export PKG_CONFIG_ALLOW_SYSTEM_CFLAGS=1
export PKG_CONFIG_ALLOW_SYSTEM_LIBS=1

checkout_source 'FFmpeg'
checkout_source 'libass'
checkout_source 'libplacebo'
checkout_source 'mpv'

ffmpeg_source="$source_root/FFmpeg"
libass_source="$source_root/libass"
libplacebo_source="$source_root/libplacebo"
mpv_source_cache="$source_root/mpv"
mpv_source="$mpv_source_cache"
ffmpeg_build="$build_output_root/ffmpeg"
libass_build="$build_output_root/libass"
libplacebo_build="$build_output_root/libplacebo"
mpv_build="$build_output_root/mpv"

if [[ "$runtime_flavor" == 'lgpl-libmpv-rife-dev' ]]; then
    rife_filter_source="$repo_root/native/mpv-rife-filter/vf_plainvideo_rife.c"
    rife_filter_patch="$repo_root/native/mpv-rife-filter/mpv-v0.41.0-rife-filter.patch"
    [[ -f "$rife_filter_source" ]] || fail "Missing RIFE mpv filter source: $rife_filter_source"
    [[ -f "$rife_filter_patch" ]] || fail "Missing RIFE mpv filter patch: $rife_filter_patch"
    mpv_source="$build_output_root/mpv-source-rife"
    git clone --no-hardlinks "$mpv_source_cache" "$mpv_source"
    git -C "$mpv_source" checkout --detach "$(source_field mpv commit)"
    cp "$rife_filter_source" "$mpv_source/video/filter/vf_plainvideo_rife.c"
    git -C "$mpv_source" apply "$rife_filter_patch"
    git -C "$mpv_source" diff --check
    cp "$rife_filter_patch" "$evidence_root/mpv-rife-filter.patch"
    cp "$rife_filter_source" "$evidence_root/vf_plainvideo_rife.c"
fi

for argument_set in ffmpegConfigure libassMeson libplaceboMeson mpvMeson; do
    profile_array "$argument_set" > "$evidence_root/$argument_set.args"
done

mkdir -p "$ffmpeg_build"
mapfile -t ffmpeg_arguments < <(tr -d '\r' < "$evidence_root/ffmpegConfigure.args")
(
    cd "$ffmpeg_build"
    "$ffmpeg_source/configure" --prefix="$prefix" --arch=x86_64 --target-os=mingw32 --cc=clang --cxx=clang++ "${ffmpeg_arguments[@]}"
)
make -C "$ffmpeg_build" -j"$PLAINVIDEO_JOBS"
make -C "$ffmpeg_build" install

configure_meson "$libass_source" "$libass_build" "$evidence_root/libassMeson.args"
meson compile -C "$libass_build" -j "$PLAINVIDEO_JOBS"
meson install -C "$libass_build"

configure_meson "$libplacebo_source" "$libplacebo_build" "$evidence_root/libplaceboMeson.args"
meson compile -C "$libplacebo_build" -j "$PLAINVIDEO_JOBS"
meson install -C "$libplacebo_build"

configure_meson "$mpv_source" "$mpv_build" "$evidence_root/mpvMeson.args"
meson compile -C "$mpv_build" -j "$PLAINVIDEO_JOBS"
meson install -C "$mpv_build"

for build in "$ffmpeg_build" "$libass_build" "$libplacebo_build" "$mpv_build"; do
    name="$(basename "$build")"
    meson introspect --buildoptions "$build" > "$evidence_root/$name-meson-options.json" 2>/dev/null || true
done
cp "$ffmpeg_build/config.h" "$evidence_root/ffmpeg-config.h"
# FFmpeg 8.x writes the generated make configuration under ffbuild/ rather
# than the build root. Keep the evidence path stable while copying the real
# configured input.
cp "$ffmpeg_build/ffbuild/config.mak" "$evidence_root/ffmpeg-config.mak"
pacman -Q > "$evidence_root/pacman-Q.txt"
{
    clang --version | head -n 1
    meson --version
    nasm -v
    pkg-config --version
} > "$evidence_root/tool-versions.txt"

copy_license() {
    local source="$1" target="$2"
    shift 2
    for candidate in "$@"; do
        if [[ -f "$source/$candidate" ]]; then
            cp "$source/$candidate" "$licenses_root/$target"
            return
        fi
    done
    fail "No license file found for $target"
}
copy_license "$mpv_source" 'mpv-LICENSE.LGPL' 'LICENSE.LGPL'
copy_license "$ffmpeg_source" 'FFmpeg-COPYING.LGPLv2.1' 'COPYING.LGPLv2.1' 'COPYING.LGPLv3'
copy_license "$libplacebo_source" 'libplacebo-LICENSE' 'LICENSE'
copy_license "$libass_source" 'libass-COPYING' 'COPYING'

if command -v objdump >/dev/null 2>&1; then
    objdump_command='objdump'
elif command -v llvm-objdump >/dev/null 2>&1; then
    objdump_command='llvm-objdump'
else
    fail 'No objdump or llvm-objdump command is available for runtime closure.'
fi

dll_imports() {
    "$objdump_command" -p "$1" | sed -n 's/^[[:space:]]*DLL Name: //p' | sort -fu
}
is_system_dll() {
    [[ "$1" =~ ^([Aa][Pp][Ii]-[Mm][Ss]-[Ww][Ii][Nn]-|[Ee][Xx][Tt]-[Mm][Ss]-[Ww][Ii][Nn]-) ]] && return 0
    [[ -f "/c/Windows/System32/$1" ]]
}
find_dependency_dll() {
    local name="$1" directory
    for directory in "$prefix/bin" /clang64/bin; do
        if [[ -f "$directory/$name" ]]; then
            printf '%s\n' "$directory/$name"
            return 0
        fi
    done
    return 1
}

mapfile -t libmpv_candidates < <(find "$prefix/bin" -maxdepth 1 -type f -iname 'libmpv-2.dll' -print)
[[ ${#libmpv_candidates[@]} -eq 1 ]] || fail "Expected exactly one installed libmpv-2.dll, found ${#libmpv_candidates[@]}"

declare -A copied_runtime_names=()
runtime_queue=()
copy_runtime_dll() {
    local source="$1" name destination
    name="$(basename "$source")"
    destination="$runtime_root/$name"
    if [[ -n "${copied_runtime_names[$name]:-}" ]]; then
        cmp --silent "$source" "$destination" || fail "Conflicting DLLs share runtime name: $name"
        return
    fi
    cp -p "$source" "$destination"
    copied_runtime_names[$name]=1
    runtime_queue+=("$destination")
}

copy_runtime_dll "${libmpv_candidates[0]}"
: > "$evidence_root/runtime-imports.txt"
for ((index = 0; index < ${#runtime_queue[@]}; index++)); do
    current="${runtime_queue[$index]}"
    while IFS= read -r import_name; do
        [[ -n "$import_name" ]] || continue
        printf '%s -> %s\n' "$(basename "$current")" "$import_name" >> "$evidence_root/runtime-imports.txt"
        if is_system_dll "$import_name"; then
            continue
        fi
        dependency_path="$(find_dependency_dll "$import_name" || true)"
        [[ -n "$dependency_path" ]] || fail "Non-system DLL dependency not found: $import_name (needed by $(basename "$current"))"
        copy_runtime_dll "$dependency_path"
    done < <(dll_imports "$current")
done
sort -fu "$evidence_root/runtime-imports.txt" -o "$evidence_root/runtime-imports.txt"

python - "$repo_root" "$runtime_root" "$profile" "$output_root/runtime-manifest.json" <<'PY'
import hashlib
import json
import os
import sys
from pathlib import Path

repo_root = Path(sys.argv[1]).resolve()
runtime_root = Path(sys.argv[2]).resolve()
profile_path = Path(sys.argv[3]).resolve()
manifest_path = Path(sys.argv[4]).resolve()
profile = json.loads(profile_path.read_text(encoding='utf-8'))

def digest(path):
    hasher = hashlib.sha256()
    with Path(path).open('rb') as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b''):
            hasher.update(block)
    return hasher.hexdigest()

required_exports = [
    'mpv_client_api_version', 'mpv_create', 'mpv_initialize',
    'mpv_terminate_destroy', 'mpv_set_option_string', 'mpv_command',
    'mpv_get_property_string', 'mpv_free', 'mpv_set_wakeup_callback',
    'mpv_wait_event', 'mpv_error_string', 'mpv_render_context_create',
    'mpv_render_context_set_update_callback', 'mpv_render_context_update',
    'mpv_render_context_render', 'mpv_render_context_report_swap',
    'mpv_render_context_free',
]
files = []
for path in sorted(runtime_root.rglob('*')):
    if not path.is_file():
        continue
    is_libmpv = path.name.lower() == 'libmpv-2.dll'
    files.append({
        'role': 'libmpv' if is_libmpv else 'dependency',
        'path': path.relative_to(runtime_root).as_posix(),
        'kind': 'library',
        'sha256': digest(path),
        'requiredExports': required_exports if is_libmpv else [],
    })
if not any(item['role'] == 'libmpv' for item in files):
    raise SystemExit('staged candidate runtime does not contain libmpv-2.dll')

payload = {
    'schemaVersion': 2,
    'status': 'candidate-not-release-approved',
    'purpose': 'Windows x64 shared-libmpv redistribution candidate; structural build evidence only',
    'architecture': 'x86_64',
    'runtimeRoot': os.path.relpath(runtime_root, repo_root).replace('\\\\', '/'),
    'profile': {'path': os.path.relpath(profile_path, repo_root).replace('\\\\', '/'), 'sha256': digest(profile_path)},
    'runtimeFiles': files,
    'licenseDisposition': 'Candidate only. Legal and distribution review are incomplete.',
    'releaseEligible': False,
}
manifest_path.write_text(json.dumps(payload, indent=2) + '\n', encoding='utf-8')
PY

python - "$output_root" "$profile" "$build_id" <<'PY'
import hashlib
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

output_root = Path(sys.argv[1]).resolve()
profile_path = Path(sys.argv[2]).resolve()
build_id = sys.argv[3]
runtime_manifest_path = output_root / 'runtime-manifest.json'

def digest(path):
    hasher = hashlib.sha256()
    with Path(path).open('rb') as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b''):
            hasher.update(block)
    return hasher.hexdigest()

files = []
for path in sorted(output_root.rglob('*')):
    relative_path = path.relative_to(output_root)
    if not path.is_file() or path.name == 'build-inventory.json':
        continue
    # Wrapper-owned stdout/stderr logs are still open while this script exits,
    # so their bytes are not a stable build input or candidate payload.
    if relative_path.parts and relative_path.parts[0] == 'logs':
        continue
    files.append({'path': relative_path.as_posix(), 'size': path.stat().st_size, 'sha256': digest(path)})
if not runtime_manifest_path.is_file():
    raise SystemExit(f'candidate runtime manifest is missing: {runtime_manifest_path}')
payload = {
    'schemaVersion': 2,
    'generatedAt': datetime.now(timezone.utc).isoformat(),
    'status': 'candidate-not-release-approved',
    'buildId': build_id,
    'buildPrefixPolicy': 'fresh per-run prefix; prefix reuse is refused',
    'buildDirectoryPolicy': 'fresh per-run build directory; build directory reuse is refused',
    'profileSha256': digest(profile_path),
    'runtimeManifestSha256': digest(runtime_manifest_path),
    'releaseEligible': False,
    'releaseBlockers': [
        'MSYS2 package cache and transitive dependency source closure are not locked for redistribution.',
        'Build evidence is not legal, patent, corresponding-source, or Store approval.',
        'Playback validation with this exact runtime has not completed.',
    ],
    'files': files,
}
(output_root / 'build-inventory.json').write_text(json.dumps(payload, indent=2) + '\n', encoding='utf-8')
PY

printf 'Candidate runtime staged at %s\n' "$(cygpath -w "$output_root")"
printf '%s\n' 'This output is intentionally not release-eligible.'
