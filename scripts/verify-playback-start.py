"""Bounded Windows startup/replacement probes against an explicitly staged build.

Uses delayed local named pipes, isolated settings/history, native
message-response probes, and window-only PNG captures. Never rebuilds, publishes,
or touches an installed player. Python standard library only.
"""
import argparse
import ctypes as C
from ctypes import wintypes as W
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import threading
import time
import zlib

user = C.WinDLL("user32", use_last_error=True)
gdi = C.WinDLL("gdi32", use_last_error=True)
kernel = C.WinDLL("kernel32", use_last_error=True)
CALLBACK = C.WINFUNCTYPE(W.BOOL, W.HWND, W.LPARAM)


def bind(dll, name, result, *arguments):
    function = getattr(dll, name)
    function.restype, function.argtypes = result, arguments
    return function


enum_windows = bind(user, "EnumWindows", W.BOOL, CALLBACK, W.LPARAM)
enum_children = bind(user, "EnumChildWindows", W.BOOL, W.HWND, CALLBACK, W.LPARAM)
window_pid = bind(user, "GetWindowThreadProcessId", W.DWORD, W.HWND, C.POINTER(W.DWORD))
visible = bind(user, "IsWindowVisible", W.BOOL, W.HWND)
class_name = bind(user, "GetClassNameW", C.c_int, W.HWND, W.LPWSTR, C.c_int)
window_text = bind(user, "GetWindowTextW", C.c_int, W.HWND, W.LPWSTR, C.c_int)
window_rect = bind(user, "GetWindowRect", W.BOOL, W.HWND, C.POINTER(W.RECT))
set_position = bind(user, "SetWindowPos", W.BOOL, W.HWND, W.HWND, C.c_int, C.c_int, C.c_int, C.c_int, W.UINT)
send_timeout = bind(user, "SendMessageTimeoutW", C.c_size_t, W.HWND, W.UINT, W.WPARAM, W.LPARAM, W.UINT, W.UINT, C.POINTER(C.c_size_t))
post = bind(user, "PostMessageW", W.BOOL, W.HWND, W.UINT, W.WPARAM, W.LPARAM)
get_dc = bind(user, "GetDC", W.HDC, W.HWND)
release_dc = bind(user, "ReleaseDC", C.c_int, W.HWND, W.HDC)
create_dc = bind(gdi, "CreateCompatibleDC", W.HDC, W.HDC)
delete_dc = bind(gdi, "DeleteDC", W.BOOL, W.HDC)
select = bind(gdi, "SelectObject", W.HANDLE, W.HDC, W.HANDLE)
delete = bind(gdi, "DeleteObject", W.BOOL, W.HANDLE)
dib = bind(gdi, "CreateDIBSection", W.HBITMAP, W.HDC, C.c_void_p, W.UINT, C.POINTER(C.c_void_p), W.HANDLE, W.DWORD)
print_window = bind(user, "PrintWindow", W.BOOL, W.HWND, W.HDC, W.UINT)
allocate = bind(kernel, "GlobalAlloc", W.HGLOBAL, W.UINT, C.c_size_t)
lock = bind(kernel, "GlobalLock", C.c_void_p, W.HGLOBAL)
unlock = bind(kernel, "GlobalUnlock", W.BOOL, W.HGLOBAL)
free = bind(kernel, "GlobalFree", W.HGLOBAL, W.HGLOBAL)
create_pipe = bind(kernel, "CreateNamedPipeW", W.HANDLE, W.LPCWSTR, W.DWORD, W.DWORD, W.DWORD, W.DWORD, W.DWORD, W.DWORD, C.c_void_p)
connect_pipe = bind(kernel, "ConnectNamedPipe", W.BOOL, W.HANDLE, C.c_void_p)
write_file = bind(kernel, "WriteFile", W.BOOL, W.HANDLE, C.c_void_p, W.DWORD, C.POINTER(W.DWORD), C.c_void_p)
close_handle = bind(kernel, "CloseHandle", W.BOOL, W.HANDLE)


def windows(pid, parent=None):
    result = []

    @CALLBACK
    def collect(hwnd, _):
        found = W.DWORD()
        window_pid(hwnd, C.byref(found))
        if found.value == pid and visible(hwnd):
            text = C.create_unicode_buffer(256)
            class_name(hwnd, text, len(text))
            result.append((hwnd, text.value))
        return True

    if parent is None:
        enum_windows(collect, 0)
    else:
        enum_children(parent, collect, 0)
    return result


def capture(hwnd, path):
    rect = W.RECT()
    if not window_rect(hwnd, C.byref(rect)):
        raise OSError("GetWindowRect failed")
    width, height = rect.right - rect.left, rect.bottom - rect.top
    header = C.create_string_buffer(struct.pack("<IiiHHIIiiII", 40, width, -height, 1, 32, 0, width * height * 4, 0, 0, 0, 0))
    source = get_dc(hwnd)
    dc = create_dc(source)
    bits = C.c_void_p()
    bitmap = dib(dc, header, 0, C.byref(bits), None, 0)
    if not dc or not bitmap:
        if dc:
            delete_dc(dc)
        release_dc(hwnd, source)
        raise OSError("Could not allocate capture surface")
    old = select(dc, bitmap)
    try:
        if not print_window(hwnd, dc, 2):
            raise OSError("PrintWindow failed")
        bgra = C.string_at(bits, width * height * 4)
        rows = bytearray()
        for y in range(height):
            rows.append(0)
            row = bgra[y * width * 4:(y + 1) * width * 4]
            rgb = bytearray(width * 3)
            rgb[0::3], rgb[1::3], rgb[2::3] = row[2::4], row[1::4], row[0::4]
            rows.extend(rgb)

        def chunk(kind, data):
            return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

        path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))
        return len(set(rows)) > 16
    finally:
        select(dc, old)
        delete(bitmap)
        delete_dc(dc)
        release_dc(hwnd, source)


def bounded_capture(hwnd, path):
    # PrintWindow has no timeout and marshals the HDC across processes. Bound it
    # in an owned helper rather than sending a process-local HDC to another app.
    try:
        result = subprocess.run([sys.executable, __file__, "--capture-notice", str(hwnd), str(path)],
                                timeout=2, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return result.returncode == 0
    except subprocess.TimeoutExpired:
        return False


def drop_file(hwnd, path):
    payload = struct.pack("<IiiII", 20, 0, 0, 0, 1) + (str(path) + "\0\0").encode("utf-16le")
    memory = allocate(2, len(payload))
    address = lock(memory)
    if not address:
        if memory:
            free(memory)
        raise OSError("Could not create file-drop payload")
    C.memmove(address, payload, len(payload))
    unlock(memory)
    if not post(hwnd, 0x233, memory, 0):
        free(memory)
        raise OSError("Could not post file drop")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--portable-root", type=Path, required=True)
    parser.add_argument("--media", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    root, evidence, media = args.portable_root.resolve(), args.evidence.resolve(), args.media.resolve()
    if not evidence.is_relative_to(repo / ".runtime") or evidence.exists():
        raise ValueError("Use a new evidence directory inside this repository's .runtime")
    executable = root / "plainvideo.exe"
    if not executable.is_file():
        raise FileNotFoundError(executable)
    payload = media.read_bytes()
    evidence.mkdir(parents=True)
    newest = evidence / "latest-request.mp4"
    newest.write_bytes(payload)
    # The shipped runtime is local-file only. Named pipes exercise actual slow
    # reads without adding network support or changing that runtime.
    def pipe_source(name):
        path = rf"\\.\pipe\PlainVideoStartup-{os.getpid()}-{name}.mp4"
        listening = threading.Event()
        release_at = time.monotonic() + (11.5 if "slow" in name else 2.5)

        def serve():
            while True:
                pipe = create_pipe(path, 2, 0, 255, 65536, 65536, 0, None)
                if pipe == C.c_void_p(-1).value:
                    listening.set()
                    return
                listening.set()
                connected = connect_pipe(pipe, None) or C.get_last_error() == 535
                if not connected:
                    close_handle(pipe)
                    return
                def send(handle=pipe):
                    try:
                        # Metadata probes can connect before mpv reads. Delay
                        # every connection to a shared release time.
                        time.sleep(max(0, release_at - time.monotonic()))
                        for offset in range(0, len(payload), 65536):
                            block = payload[offset:offset + 65536]
                            written = W.DWORD()
                            if not write_file(handle, block, len(block), C.byref(written), None):
                                break
                    finally:
                        close_handle(handle)

                threading.Thread(target=send, daemon=True).start()

        threading.Thread(target=serve, daemon=True).start()
        if not listening.wait(3):
            raise RuntimeError("Named pipe did not start")
        return path
    cases = [
        ("opening-ko-dark", "ko-KR", "dark", 680, 420, "1", 8000),
        ("slow-en-light-small", "en-US", "light", 360, 300, "2", 15000),
        ("replace-pending-open", "ko-KR", "dark", 680, 420, "1", 6500),
    ]
    results = []
    try:
        for name, locale, theme, width, height, scale, exit_ms in cases:
            settings = evidence / f"{name}.ini"
            settings.write_text(f"version=6\ntheme={theme}\nvolume=0\nmuted=true\n", encoding="utf-8")
            env = os.environ.copy()
            # Do not inherit diagnostic scenarios or experimental overrides.
            for key in list(env):
                if key.startswith("PLAINVIDEO_"):
                    env.pop(key)
            env.update(PLAINVIDEO_ROOT=str(root), PLAINVIDEO_SETTINGS_PATH=str(settings),
                       PLAINVIDEO_RESUME_PATH=str(evidence / f"{name}.resume"),
                       PLAINVIDEO_DIAGNOSTIC_LOG=str(evidence / f"{name}.log"),
                       PLAINVIDEO_DIAGNOSTIC_EXIT_MS=str(exit_ms), PLAINVIDEO_DIAGNOSTIC_SINGLE_FILE="1",
                       PLAINVIDEO_LOCALE=locale, PLAINVIDEO_TEXT_SCALE=scale)
            source = pipe_source(name)
            process = subprocess.Popen([str(executable), source], cwd=root, env=env,
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            started, hwnd, captured, retried, replaced = time.monotonic(), None, set(), False, False
            response_ms, response_failures = [], 0
            loading_seen, hidden_after_ready = False, False
            final_title = ""
            try:
                while process.poll() is None and time.monotonic() - started < exit_ms / 1000 + 8:
                    elapsed = time.monotonic() - started
                    if hwnd is None:
                        candidates = windows(process.pid)
                        if candidates:
                            hwnd = candidates[0][0]
                            set_position(hwnd, None, 60, 60, width, height, 0x14)
                    if hwnd and visible(hwnd):
                        before = time.perf_counter()
                        answer = C.c_size_t()
                        success = send_timeout(hwnd, 0, 0, 0, 2, 200, C.byref(answer))
                        response_ms.append(round((time.perf_counter() - before) * 1000, 3))
                        response_failures += not bool(success)
                        notices = [(h, cls) for h, cls in windows(process.pid, hwnd) if cls == "PlainVideo.LoadingNotice"]
                        loading_seen |= bool(notices)
                        trace_path = evidence / f"{name}.startup.log"
                        trace = trace_path.read_text(encoding="utf-8") if trace_path.exists() else ""
                        if "stage=playback-ready" in trace and not notices:
                            hidden_after_ready = True
                            title = C.create_unicode_buffer(1024)
                            window_text(hwnd, title, len(title))
                            final_title = title.value
                        if notices and "opening" not in captured and elapsed > 1:
                            if bounded_capture(notices[0][0], evidence / f"{name}-opening.png"):
                                captured.add("opening")
                        if name.startswith("slow") and notices and elapsed > 10.8 and "slow" not in captured:
                            if bounded_capture(notices[0][0], evidence / f"{name}-slow.png"):
                                captured.add("slow")
                                post(hwnd, 0x100, ord("R"), 0)
                                retried = True
                        if name.startswith("replace") and elapsed > 1.2 and not replaced:
                            drop_file(hwnd, media)
                            # A second request exercises late events and latest intent.
                            drop_file(hwnd, newest)
                            replaced = True
                    time.sleep(0.1)
                timed_out = process.poll() is None
                if timed_out:
                    process.kill()
                process.wait(timeout=5)
                trace_path = evidence / f"{name}.startup.log"
                trace = trace_path.read_text(encoding="utf-8") if trace_path.exists() else ""
                log = (evidence / f"{name}.log").read_text(encoding="utf-8", errors="replace")
                result = dict(name=name, exitCode=process.returncode, timedOut=timed_out,
                              responseFailures=response_failures, maxResponseMs=max(response_ms, default=None),
                              loadingSeen=loading_seen, hiddenAfterReady=hidden_after_ready,
                              finalTitle=final_title,
                              retrySent=retried, replacementSent=replaced,
                              readyCount=trace.count("stage=playback-ready"), firstFrame="first video frame after restart shown" in log)
                result["passed"] = (not timed_out and process.returncode == 0 and response_failures == 0 and hidden_after_ready and result["firstFrame"]
                                    and ((loading_seen and "opening" in captured) or name.startswith("replace")))
                if name.startswith("slow"):
                    result["passed"] &= retried and any(line.startswith("generation=2 ") and "stage=playback-ready" in line for line in trace.splitlines())
                if name.startswith("replace"):
                    result["passed"] &= replaced and any(line.startswith("generation=3 ") and "stage=playback-ready" in line for line in trace.splitlines())
                    result["passed"] &= "latest-request.mp4" in final_title
                results.append(result)
                print(json.dumps(result), flush=True)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=5)
    finally:
        # All pipe servers are daemon threads in this bounded probe process.
        # Exiting closes their pending pipe instances; no helper process remains.
        pass
    summary = dict(executable=str(executable), exeSha256=hashlib.sha256(executable.read_bytes()).hexdigest(),
                   mediaSha256=hashlib.sha256(payload).hexdigest(), cases=results,
                   passed=len(results) == len(cases) and all(case["passed"] for case in results))
    (evidence / "summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    raise SystemExit(0 if summary["passed"] else 1)


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "--capture-notice":
        raise SystemExit(0 if capture(int(sys.argv[2]), Path(sys.argv[3])) else 2)
    main()
