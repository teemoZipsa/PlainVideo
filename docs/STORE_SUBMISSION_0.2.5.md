# Microsoft Store Submission — PlainVideo 0.2.5

## Target

- Product ID: `9PDKQ88FKG1L`
- Identity: `SeonkyuIM.PlainVideo`
- Version: `0.2.5.0`
- Architecture: `x64`
- Device family: `Windows.Desktop`
- Minimum version: `10.0.17763.0`
- Distribution: free, no ads, no account, no telemetry

## Release scope

- Attach supported subtitles by dropping them onto active playback.
- Remember subtitle-off, embedded-track, and external-file choices per video.
- Normalize UTF-8 and UTF-16 SMI for reliable playback without changing the
  original file.
- Adjust and persist subtitle size from 50% to 200%.
- Use directional single-click ten-second seeking and center play/pause.
- Keep playback keyboard shortcuts active while context-menu mouse actions are
  isolated from playback.
- Stabilize the redesigned control window during high-resolution playback and
  suppress background busy-cursor UI wakeups in fullscreen.
- Include default-off 24→48 and explicitly experimental, default-off 30→60
  smooth playback with source-frame fallback.

## Korean Store release notes

영상별 자막 꺼짐·내장 트랙·외부 파일을 기억하고 다시 실행해도 복원합니다.
SMI 자막 끌어 놓기와 파일 선택을 보강하고, 자막 크기를 50~200%로 조절할
수 있습니다. 왼쪽·오른쪽 한 번 클릭 10초 탐색, 우클릭 메뉴 중 단축키,
전체 화면 커서 숨김, 4K 재생 중 제어창 안정성을 개선했습니다. 기본 꺼짐
24→48과 실험적 30→60 부드러운 재생을 추가했으며, 부하가 높으면 원본
프레임으로 자동 전환합니다.

## English Store release notes

PlainVideo now remembers subtitle-off, embedded-track, and external-file
choices per video, restores them across launches, improves SMI drag-and-drop
and file selection, and adds persistent 50–200% subtitle sizing. Directional
single-click seeking, context-menu keyboard shortcuts, fullscreen cursor
hiding, and control-window stability during 4K playback are improved. Optional
24→48 and experimental 30→60 smooth playback are disabled by default and
automatically fall back to source frames under load.

## State boundary

Partner Center currently confirms Submission 4 / 0.2.3 as available in the
Microsoft Store. The 0.2.5 package has not yet been uploaded, certified, or
published. Update this section only from direct evidence.
