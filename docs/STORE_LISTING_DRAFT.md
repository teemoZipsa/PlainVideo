# Microsoft Store listing draft

Status: product name reserved; Submission 1 bilingual copy is saved; localized screenshots are generated and visually verified locally but not uploaded or submitted

Keep the two locales as separate Partner Center listing entries. Do not paste Korean and English into one field.

## English — en-US

### Product name

PlainVideo

Reserved in Partner Center on 2026-07-21.

### Short description

A calm, borderless local video player that keeps controls out of the way.

### Description

PlainVideo puts the video first. Open a local file and start watching in a borderless Windows window, with familiar controls that appear only when you need them.

Click to play or pause, double-click for fullscreen, use the arrow keys to seek or change volume, and open subtitle controls from the transient playback bar or context menu. PlainVideo automatically discovers matching external subtitles and remembers a safe physical window position across monitors.

PlainVideo is designed for local playback. It has no ads, accounts, recommendations, or telemetry. The source code and third-party license information are public.

The first Store release will list only formats and hardware paths verified against its exact packaged playback runtime.

### Features

- Borderless, content-first local playback
- Click play/pause and double-click fullscreen
- Compact controls that disappear after inactivity
- External subtitle discovery and track selection
- Multi-monitor physical window placement
- Korean and English interface
- No ads, accounts, or telemetry
- Open-source code and explicit third-party notices

### Keywords

- video player
- local video
- subtitles
- borderless
- mp4
- mkv
- media player

## 한국어 — ko-KR

### 제품 이름

PlainVideo

2026-07-21 Partner Center에서 이름을 예약했습니다.

### 간단한 설명

조작부는 조용히 숨기고 영상에 집중하는 테두리 없는 로컬 동영상 플레이어입니다.

### 설명

PlainVideo는 영상을 화면의 중심에 둡니다. 로컬 파일을 열면 테두리 없는 Windows 창에서 바로 재생하며, 익숙한 조작부는 필요할 때만 나타납니다.

클릭으로 재생하거나 일시정지하고, 더블 클릭으로 전체화면을 전환하며, 방향키로 탐색과 볼륨을 조절할 수 있습니다. 잠깐 나타나는 재생 바와 우클릭 메뉴에서 자막을 고를 수 있고, 같은 이름의 외부 자막을 자동으로 찾습니다. 모니터를 옮겨도 안전한 물리 픽셀 창 위치를 기억합니다.

PlainVideo는 로컬 재생을 위한 앱입니다. 광고, 계정, 추천 피드, 텔레메트리가 없습니다. 소스 코드와 제3자 라이선스 정보도 공개합니다.

첫 Store 버전은 실제 패키지에 포함된 재생 런타임으로 검증한 형식과 하드웨어 경로만 지원 범위로 표시합니다.

### 주요 기능

- 영상 중심의 테두리 없는 로컬 재생
- 클릭 재생/일시정지와 더블 클릭 전체화면
- 사용하지 않으면 사라지는 간결한 조작부
- 외부 자막 자동 탐색과 트랙 선택
- 모니터별 물리 픽셀 창 위치 기억
- 한국어와 영어 인터페이스
- 광고·계정·텔레메트리 없음
- 공개 소스 코드와 명시적인 제3자 고지

### 검색어

- 동영상 플레이어
- 로컬 동영상
- 자막
- 무테두리
- MP4
- MKV
- 미디어 플레이어

## Planned listing media

Prepared language-neutral Store artwork candidates:

- `assets/store-listing/upload/<locale>/poster-1440x2160.png`
- `assets/store-listing/upload/<locale>/box-art-2160x2160.png`
- `assets/store-listing/upload/shared/app-tile-300x300.png`
- `assets/store-listing/upload/shared/store-logo-150x150.png`
- `assets/store-listing/upload/shared/store-logo-71x71.png`

The `en-US` and `ko-KR` poster/box-art copies are identical because they contain
only the `PlainVideo` product name.

The 300 x 300 app tile is documented for apps. Microsoft's current MSIX listing
guidance describes poster and box art as game fields, and the exact use of the
150 x 150 and 71 x 71 candidates has not been verified in PlainVideo's Partner
Center listing. Do not count those files as submission-ready fields until the
actual listing confirms an applicable destination.

Rights-cleared 1600×900 PNG captures have been generated separately for each
locale from PlainVideo and repository-generated deterministic smoke media:

1. `01-drop-zone.png`
2. `02-content-first-playback.png`
3. `03-transient-controls.png`
4. `04-subtitle-menu.png`

Shared logos and non-text art belong under `assets/store-listing/upload/shared`.
Localized screenshots live under `assets/store-listing/upload/en-US/screenshots`
and `assets/store-listing/upload/ko-KR/screenshots`. Regenerate them from the
final clean release commit before upload and keep the recorded SHA-256 evidence
with the release record.
