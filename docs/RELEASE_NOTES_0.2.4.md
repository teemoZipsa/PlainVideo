# PlainVideo 0.2.4 release notes

Status: local release candidate. Certification, publication, and Microsoft
Store delivery remain separate states until directly verified.

## 한국어

- 재생 중인 영상에 `.smi`, `.srt`, `.ass`, `.ssa`, `.vtt`, `.sub` 자막을
  끌어 놓으면 영상을 바꾸지 않고 즉시 추가합니다.
- 영상별로 마지막에 직접 추가한 외부 자막을 기억하고, 같은 영상을 다시
  열거나 앱을 다시 실행해도 자동으로 복원합니다. 자막 파일이 사라진
  경우에는 안전하게 건너뜁니다.
- 영상 왼쪽·오른쪽을 한 번 클릭하면 10초 전·후로 이동하고 해당 방향에
  짧은 시각 효과를 표시합니다. 가운데 한 번 클릭은 재생/일시정지,
  가운데 더블클릭은 전체 화면입니다.
- Windows 파일 연결을 MP4·MKV뿐 아니라 WebM, MOV, AVI, M4V, M2TS, MTS,
  TS, MPG, MPEG, WMV, OGV까지 확대하고 한국어·영어 연결 이름과 탐색기
  아이콘을 보강했습니다.
- 독립형 재생 제어 창과 30→60 실험 버튼을 추가했습니다. Microsoft Store
  패키지는 검증된 1080p 24→48만 선택적으로 제공하며, 승인 전인 30→60과
  4K 호환 경로는 포함된 기능 매니페스트에 따라 비활성화합니다.

## English

- Drop an `.smi`, `.srt`, `.ass`, `.ssa`, `.vtt`, or `.sub` subtitle onto
  active playback to attach it without replacing the video.
- PlainVideo remembers the last manually attached external subtitle per video
  and restores it when that video or the app is opened again. Missing subtitle
  files are skipped safely.
- Single-click the left or right video region to seek back or forward ten
  seconds with directional feedback. A center click toggles play/pause and a
  center double-click toggles fullscreen.
- Windows file associations now cover WebM, MOV, AVI, M4V, M2TS, MTS, TS, MPG,
  MPEG, WMV, and OGV in addition to MP4 and MKV, with localized association
  names and improved Explorer icons.
- Added an independent playback-control window and an experimental 30→60
  control. The Microsoft Store package keeps the qualified optional 1080p
  24→48 path; unapproved 30→60 and 4K compatibility paths remain disabled by
  the included feature manifest.
