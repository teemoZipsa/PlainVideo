PlainVideo portable proof template

Run:
  plainvideo.exe "C:\path\to\video.mkv"

You can also open a file from the right-click menu or drag a media file onto
the playback surface. The full-width invisible top zone moves the borderless
window; no visible move handle or Alt+drag override is used.

This directory is a local architecture proof, not a release artifact. Read
runtime-manifest.json and runtime-provenance.json to identify its exact runtime
and status. A developer-only runtime is conservatively treated as
GPL-2.0-or-later; a shared candidate remains unapproved until its complete
redistribution/source/notice review is finished. Do not publish or redistribute
either proof directory.

A shared candidate portable also contains source-runtime-manifest.json and
source-runtime-verification.json. The portable runtime-manifest.json describes
the copied DLLs beside plainvideo.exe, while the source files preserve the
pre-stage build evidence. Its windows-runtime-compatibility.json records the
static CRT audit, technical Windows API floor, and dynamic-load review limits;
it is not a compatibility or release approval.
