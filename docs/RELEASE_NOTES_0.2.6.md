# PlainVideo 0.2.6 release notes

Status: GitHub prerelease published and Partner Center Submission 5 submitted.
Microsoft Store certification is in pre-processing; publication and delivery
remain separate states until directly verified.

## 한국어

- SMI의 빈 자막 구간에서 `&nbsp;`, `&#160;`, `&#xA0;`가 화면에 문자로
  노출되거나 디코드 오류를 만들지 않도록 실제 보이지 않는 문자로
  정규화합니다. 대사 안의 의도된 공백은 그대로 유지합니다.
- UTF-8·UTF-16뿐 아니라 한국어 Windows-949 SMI도 원본 파일을 수정하지
  않고 안전하게 재생합니다. 잘린 UTF-16 입력은 임의로 변환하지 않습니다.
- 정규화한 자막 캐시는 임시 파일을 완전히 기록한 뒤 원자적으로 교체하며,
  현재 사용 중인 파일을 보존하면서 최근 64개로 자동 정리합니다.
- 재생 컨트롤이 숨겨진 상태에서도 우측 상단 닫기 영역이 창 이동 영역으로
  바뀌지 않도록 수정해, 마우스를 올린 뒤 닫기 버튼을 정상 클릭할 수 있습니다.
- 영상별 자막 꺼짐·내장 트랙·외부 파일 복원, 50–200% 자막 크기, 자막
  끌어 놓기와 파일 선택, 방향 클릭 탐색 등 0.2.5의 재생 개선을 포함합니다.
- 24→48 부드러운 재생과 실험적 30→60은 지원 런타임을 포함한 Windows
  x64 패키지에서만 표시되며 둘 다 기본 꺼짐입니다. 처리 여유가 부족하면
  원본 프레임으로 자동 전환합니다.

## English

- Empty SMI cues using `&nbsp;`, `&#160;`, or `&#xA0;` are normalized to a real
  invisible character instead of being displayed literally or causing decoder
  errors. Intentional spacing inside dialogue is preserved.
- Korean Windows-949 SMI is handled alongside UTF-8 and UTF-16 without changing
  the original file. Truncated UTF-16 input is not rewritten.
- Normalized subtitle caches are atomically replaced and bounded to the 64 most
  recent entries while preserving the current file.
- The hidden top-right window-control area no longer becomes a drag target, so
  the close button remains clickable when controls appear.
- This release includes the subtitle restore, persistent 50–200% subtitle size,
  subtitle drop/picker, and directional click-seeking improvements from 0.2.5.
- Optional 24→48 and experimental 30→60 smooth playback remain disabled by
  default and require the supported Windows x64 runtime. Both fall back to
  source frames under load.
