# Microsoft Store Submission — PlainVideo 0.2.6

## Target

- Product ID: `9PDKQ88FKG1L`
- Identity: `SeonkyuIM.PlainVideo`
- Version: `0.2.6.0`
- Architecture: `x64`
- Device family: `Windows.Desktop`
- Minimum version: `10.0.17763.0`
- Distribution: free, no ads, no account, no telemetry

## Release scope

- Prevent literal HTML entities and decoder errors in empty SMI cues while
  preserving intentional in-dialogue spacing.
- Add guarded Korean Windows-949 SMI decoding alongside UTF-8 and UTF-16.
- Write normalized subtitle caches atomically and keep their size bounded.
- Keep the top-right close control clickable after hidden controls appear.
- Retain per-video subtitle restore, persistent subtitle sizing, subtitle drop,
  directional click seeking, and the existing default-off smooth-playback modes.

## Korean Store release notes

SMI 빈 구간의 HTML 엔티티가 문자로 보이거나 디코드 오류를 만들던 문제를
수정하고, 대사 안의 공백은 유지합니다. 한국어 Windows-949 SMI 지원과
안전한 자막 캐시 저장·자동 정리를 추가했습니다. 숨겨진 컨트롤이 나타난 뒤
우측 상단 닫기 버튼이 창 이동 영역에 막혀 클릭되지 않던 문제도 해결했습니다.

## English Store release notes

Fixed literal HTML entities and decoder errors in empty SMI cues while
preserving intentional dialogue spacing. Added guarded Korean Windows-949 SMI
support, atomic bounded subtitle caching, and fixed the top-right close button
being intercepted by the window drag area after hidden controls appeared.

## State boundary

Partner Center currently confirms Submission 4 / 0.2.3 as available in the
Microsoft Store. The 0.2.6 package has not yet been uploaded, certified, or
published. Update this section only from direct evidence.
