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

Partner Center accepted and validated
`PlainVideo_0.2.6.0_x64-store.msix` in Submission 5
(`1152921505701627822`). The package was saved and submitted for certification
on 2026-08-15. Partner Center currently shows step 2 of 4, **Pre-processing in
progress**; certification and publishing have not started.

Submission 4 / 0.2.3 remains available in the Microsoft Store. Submission 5
retains the manual publish hold, so a separate **Publish now** action will be
required after certification succeeds.

- Store MSIX SHA-256:
  `4c38c718f094ed49c8cde25186baeebd12334c48a68a85d8e72cc956ccc359bb`
- Store MSIX size: `30,719,651` bytes
- Source commit: `523560e1166e8dedea00ebd2b1bf0239f42dd1fd`
- Full validation:
  `.runtime/validation/integrated/20260815-024343-453/summary.json`
