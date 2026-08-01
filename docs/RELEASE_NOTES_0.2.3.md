# PlainVideo 0.2.3 release notes

Status: release artifacts and local gates passed; Partner Center Submission 4
is in Pre-processing with manual publication hold. Certification, publication,
and Store delivery remain separate later states.

## 한국어

- 우클릭의 `재생 제어…` 또는 `P`로 여는 임시 제어 패널을 추가했습니다.
- 패널에서 10초 탐색, 속도, A–B 구간 반복, 음소거·볼륨, 음향
  프리셋과 5밴드 이퀄라이저를 조작할 수 있습니다.
- 지원 엔진이 포함된 빌드에서 `24→48 부드러운 재생`을 선택하고 다음
  실행에도 유지할 수 있습니다. 1080p SDR 24/25fps 영상에 적용하며,
  탐색·장면 전환·과부하·오류 시 원본 프레임을 유지합니다.
- 패널은 `Tab`/`Shift+Tab`, 방향키, `Enter`/`Space`로도 조작할 수
  있습니다.

## English

- Added an on-demand playback panel opened from the right-click menu or with
  `P`.
- The panel provides 10-second seek, speed, A–B repeat, mute/volume, sound
  presets, and a five-band equalizer.
- Builds that include the qualified engine can enable and remember `Smooth
  playback 24→48`. It targets 1080p SDR 24/25 fps video and preserves source
  frames during seeks, scene changes, overload, or errors.
- The panel is operable with `Tab`/`Shift+Tab`, arrow keys, and
  `Enter`/`Space`.

The clean candidate passed the 24-to-48 native timing gate and focused playback
checks for generation, seek, scene-cut, overload, teardown, and unsupported
30 fps source fallback. The exact portable/MSIX payloads passed verification,
Defender found no threats, WACK reported PASS, and the Store MSIX was submitted
as Partner Center Submission 4. It is not yet certified or published.
