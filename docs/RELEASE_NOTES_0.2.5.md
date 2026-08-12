# PlainVideo 0.2.5 release notes

Status: local release candidate. Microsoft Store upload, certification,
publication, and delivery remain separate states until directly verified.

## 한국어

- 재생 중인 영상에 SMI·SRT·ASS·SSA·VTT·SUB·IDX·SUP 자막을 끌어 놓아
  바로 추가할 수 있습니다. SMI는 파일 선택 창에도 표시됩니다.
- 영상별 자막 꺼짐 상태, 내장 자막 트랙, 외부 자막 파일을 기억합니다.
  앱을 다시 실행해도 복원하며, 같은 자막을 중복 추가하지 않고 사라진
  파일은 안전하게 잊습니다.
- UTF-8·UTF-16 SMI를 원본 수정 없이 재생용 캐시에 정규화해 빈 자막
  구간에서 발생하던 SAMI 디코드 오류를 없앴습니다.
- 자막 크기를 50%부터 200%까지 줄이거나 키울 수 있고 설정을 유지합니다.
- 영상 왼쪽·오른쪽 한 번 클릭은 10초 전·후 탐색과 방향 효과, 가운데
  클릭은 재생/일시정지, 가운데 더블클릭은 전체 화면으로 동작합니다.
- 우클릭 메뉴가 열린 동안 마우스 클릭은 재생을 건드리지 않으며, Space·
  방향키를 포함한 재생 단축키는 계속 사용할 수 있습니다.
- 제어창을 새로 정리하고 mpv 상태 캐시·더블 버퍼링·고DPI 배치를 적용해
  4K 영상 재생 중 제어창이 떨리는 현상을 줄였습니다.
- 전체 화면·항상 위 재생 중 다른 작업의 대기 커서가 표시되더라도 재생
  UI와 마우스가 반복해서 튀어나오지 않도록 입력 감지를 분리했습니다.
- 23.976/24 fps 영상용 24→48을 기본 꺼짐 선택 기능으로 제공합니다.
  30→60도 기본 꺼짐인 실험 기능으로 제공하며, 처리 여유가 부족하면
  자동으로 원본 프레임을 사용합니다. 두 기능 모두 RIFE 런타임이 포함된
  Windows x64 패키지에서만 표시됩니다.

## English

- Drop SMI, SRT, ASS, SSA, VTT, SUB, IDX, or SUP subtitles onto active
  playback. SMI files are also visible in the subtitle picker.
- PlainVideo remembers subtitle-off, embedded-track, and external-file choices
  per video across restarts. It avoids duplicate tracks and safely forgets a
  missing external file.
- UTF-8 and UTF-16 SMI files are normalized in a playback cache without
  modifying the original, eliminating SAMI decode errors from empty cues.
- Subtitle size is adjustable from 50% to 200% and persists across launches.
- Single-click the left or right video region to seek ten seconds with
  directional feedback. Center click toggles playback; center double-click
  toggles fullscreen.
- Mouse actions do not alter playback while the context menu is open, while
  playback keyboard shortcuts remain available.
- The redesigned control window uses cached mpv state, double buffering, and
  safe high-DPI placement to prevent visible shaking during 4K playback.
- Fullscreen cursor activity from background work no longer repeatedly reveals
  playback UI while always-on-top viewing is active.
- Optional 24→48 smooth playback is available for 23.976/24 fps video and is
  disabled by default. Experimental 30→60 is also disabled by default and
  automatically falls back to source frames under load. Both require the
  Windows x64 package that includes the RIFE runtime.
