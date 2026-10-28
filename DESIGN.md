---
name: L∞P
description: White and purple customer portal with a calm operations console
colors:
  signal: "#4824c7"
  signal-ink: "#ffffff"
  ink: "#242136"
  ink-soft: "#62636e"
  paper: "#f7f7fa"
  surface: "#ffffff"
  line: "#dedee6"
  control-line: "#878793"
  info-bg: "#f0ecff"
  info-line: "#beb1ee"
  info-ink: "#4824c7"
  bar: "#242136"
  bar-ink: "#e0ddeb"
  bar-active: "#473669"
  bar-hover: "#363047"
  bar-mark: "#c8b8ff"
  ring-track: "#e8e2f5"
  ok: "#10916b"
  warn: "#b86e00"
  danger: "#c0392b"
  campaign-lilac: "#eee8fa"
  campaign-peach: "#fbede8"
  campaign-mint: "#e8f4ee"
  campaign-ink: "#292139"
  campaign-soft: "#5f536e"
  campaign-button: "#30243f"
  dark-signal: "#c1a7ff"
  dark-signal-ink: "#15141c"
  dark-ink: "#e6ebf1"
  dark-ink-soft: "#b8b6c4"
  dark-paper: "#15141c"
  dark-surface: "#211f2b"
  dark-line: "#484452"
  dark-control-line: "#918a9f"
  dark-info-bg: "#342849"
  dark-info-line: "#8466ad"
  dark-info-ink: "#d3bfff"
  dark-bar: "#1c1927"
  dark-bar-ink: "#ded9ea"
  dark-bar-active: "#483662"
  dark-bar-hover: "#332b45"
  dark-bar-mark: "#cfbdff"
typography:
  body:
    fontFamily: "'IBM Plex Sans KR', 'Apple SD Gothic Neo', 'Malgun Gothic', system-ui, sans-serif"
    fontSize: "15px"
    lineHeight: 1.65
  display:
    fontSize: "3rem"
    fontWeight: 700
    lineHeight: 1.3
    letterSpacing: "-0.04em"
  headline:
    fontSize: "2.2rem"
    fontWeight: 700
    letterSpacing: "-0.035em"
  title:
    fontSize: "1.8rem"
    fontWeight: 700
    letterSpacing: "-0.035em"
  label:
    fontSize: "0.875rem"
    fontWeight: 500
rounded:
  control: "8px"
  menu: "12px"
  surface: "16px"
  campaign: "20px"
  badge: "5px"
spacing:
  compact: "8px"
  base: "16px"
  card-gap: "24px"
  page: "32px"
  section: "64px"
components:
  button-primary:
    backgroundColor: "{colors.signal}"
    textColor: "{colors.signal-ink}"
    rounded: "{rounded.control}"
    padding: "11px 22px"
    height: "46px"
  panel:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.ink}"
    rounded: "{rounded.surface}"
    padding: "1.75rem"
---

# Design System: L∞P

## Overview

T world의 정보 구조를 참고해 기존 고객 화면을 화이트·퍼플 포털로 전면 교체한 구현의 기준이다. 2단 헤더, 목적별 메뉴, 넓은 기기 캠페인, 겹쳐 놓은 계정 요약, 요금제·혜택·바로가기·공지 흐름을 사용한다. 기존 L∞P 로고를 유지하며 SKT 상표, 실제 판매 조건, T world 상품을 복제하지 않는다.

운영 화면은 짙은 퍼플 탐색과 중립 데이터 면으로 구분한다. 이 문서는 CSS에서 추출한 현재 상태이며 별도 사용자 인터뷰로 정한 디자인 은유나 제품 약속은 추가하지 않는다. 과거 디자인 보고서는 docs/design에 보존한다.

**Key Characteristics:**
- 흰색 면과 독립적인 L∞P 퍼플.
- 한국어 산세리프, 큰 캠페인 제목과 읽기 쉬운 업무 수치.
- 고객 포털과 운영 콘솔의 목적별 탐색.
- 실제 API 데이터와 명시적인 로딩·오류·빈 상태.

## Colors

최종 기준은 `frontend/src/styles/global.css` 이후 적용되는 `frontend/src/styles/portal.css`이다. 위 토큰은 후자의 덮어쓰기를 반영한다. `dark-`는 다크 테마 대응 값이며 캠페인·인증 보조 면은 두 테마에서 밝은 고정 팔레트를 사용한다.

### Primary
- **루프 퍼플 / signal**: 주요 행동, 선택, 링크, 데이터 막대, 로고 마크. 다크 모드에서는 밝은 라벤더로 바뀐다.
- 캠페인 안의 포커스는 고정 `#4824c7`로 밝은 배경에서 구분한다.

### Neutral
- `paper`, `surface`, `line`은 페이지·면·경계, `ink`, `ink-soft`는 본문·보조 문구다.
- 입력과 보조 버튼은 `control-line`으로 경계를 강화한다.
- 운영 탐색은 `bar`, `bar-ink`, `bar-active`, `bar-hover`, `bar-mark`를 사용한다.

### Status
- 정상·주의·오류·안내의 배경·경계·문자 조합은 global.css의 의미 변수를 따른다. 색상만으로 상태를 전달하지 않는다.
- 카카오 결제 버튼 등 기존 기능의 고유 색상은 유지한다.

## Typography

IBM Plex Sans KR와 한국어 시스템 대체 글꼴을 사용한다. 본문은 15px/1.65, 수치는 tabular-nums다. 캠페인 제목은 3rem/700/1.3, 일반 페이지 제목은 2.2rem, 홈 섹션 제목은 1.8rem이다. 캠페인은 1200px 이하 2.6rem, 768px 이하 2rem로 줄어든다. 운영 페이지 제목은 1.8rem, 인증 제목은 2rem이다.

## Layout

고객 본문·헤더·푸터는 최대 1248px이다. 본문 기본 패딩은 3rem 2rem 4.5rem이다. 헤더는 74px 유틸리티 행과 70px 목적별 메뉴 행을 갖는다. 캠페인은 2열, 최소 높이 390px, 기기 이미지는 높이 290px이다. 계정 요약은 -22px 상단 여백으로 캠페인에 겹치며 4열이다. 바로가기는 6열, 추천 요금제는 3열이다.

운영 사이드바는 232px, 1024px 이하 208px, 운영 본문은 최대 1520px이다. 768px 이하에서는 사이드바·데스크톱 고객 메뉴를 모바일 메뉴로 전환한다. 요금제·혜택·활동 영역은 한 열로 바뀐다. 480px 이하에서는 캠페인 이미지를 숨기고 계정 요약은 한 열, 바로가기는 세 열로 바뀐다. 인증 화면은 데스크톱 2열이고 768px 이하에서는 이야기 영역을 숨긴다. 기존 업무 CSS의 추가 분기점도 함께 적용된다. 이 동작은 코드 정의이며 실제 기기 검증 결과가 아니다.

## Elevation & Depth

공통 면의 `--shadow`는 none이다. 계정 요약만 `0 12px 40px rgba(36,26,72,.08)`로 캠페인 위 층위를 만든다. 메뉴는 `0 8px 24px rgba(21, 32, 43, 0.12)` 그림자를 사용한다. 요금제 선택은 2px 퍼플 윤곽, 일반 면은 1px 경계로 구분한다.

## Shapes

버튼·입력은 8px, 메뉴·계정 요약은 12px, 공통 면·추천 요금제는 16px, 캠페인 아래쪽·혜택·인증 이야기 면은 20px이다. 태그는 5px, 바로가기 아이콘 바탕은 24px이다. 모든 화면을 동일한 카드 모양으로 평탄화하지 않는다.

## Components

### Buttons

주요 버튼은 signal/signal-ink, 11px 22px 패딩, 최소 높이 46px이다. 작은 버튼은 40px, 인증 제출 버튼은 52px이다. 보조 버튼은 투명 면과 control-line 경계를 사용한다. Hover는 brightness(.94), 비활성은 opacity .6과 progress 커서다. 일반 포커스는 3px signal, 2px offset이다.

### Cards / Containers

공통 패널은 surface와 line 경계, 16px 모서리, 1.75rem 패딩이다. 운영 패널은 24px 패딩이며 모바일에서 줄어든다. 계정 요약은 그림자로, 요금제는 경계로, 혜택은 옅은 색 면으로 구분한다.

### Inputs / Fields

체크박스·라디오는 일반 입력창의 전체 폭·46px 최소 높이에서 제외한다. 데스크톱은 18×18px, coarse pointer는 24×24px이며 테마의 accent-color를 사용한다. 관리자 표 셀 여백은 12×14px, 선택 열은 48px이다. 데스크톱 필터는 36px, 표 내부 작은 버튼은 32px로 줄이며 coarse pointer에서는 모두 최소 44px로 유지한다. 로그인·일반 폼 입력창 크기는 유지한다.

surface/ink, control-line 1px, 8px 모서리, 0.6rem 0.75rem 패딩을 사용한다. 최소 높이는 46px이다. 오류는 aria-invalid 경계와 오류 문구, placeholder는 ink-soft, 커서는 signal이다. 로그인·가입은 AuthFrame을 공유하며 제출 로직은 보존한다.

### Navigation

고객은 유틸리티와 목적별 탐색을 분리한다. 운영자는 고정 사이드바와 페이지 위치를 사용한다. 메뉴는 기존 바깥 클릭·Escape 닫기·트리거 포커스 복귀를 유지한다. 본문 이동 링크, 명시적인 선택 상태, 모바일 전체 메뉴를 제공한다.

### Campaign and data

홈 캠페인은 수동 3탭이며 키보드 탭 전환을 구현한다. 자동 전환은 없다. 필수 문구는 이미지 위에 겹치지 않는다. 로고 없는 생성 기기 정물 `loop-devices.webp`를 사용한다. 홈 계정·요금제·상품·공지는 기존 API를 사용하며 미수집·오류·빈 목록을 실제 상태대로 표시한다.

## Do's and Don'ts

### Do:
- **Do** 두 CSS의 적용 순서와 밝음·어두움 테마를 함께 확인한다.
- **Do** 실제 데이터와 상태 문구, 기존 권한·라우트·관제 도구 계약을 보존한다.
- **Do** 퍼플을 주요 행동과 선택에 일관되게 연결한다.

### Don't:
- **Don't** T world의 로고·상품·판매 조건을 L∞P의 실제 정보로 사용하지 않는다.
- **Don't** 디자인을 위해 API·인증·인가·Zabbix·Grafana 계약을 변경하지 않는다.
- **Don't** 코드 확인이나 빌드 성공을 브라우저·모바일·접근성 검증 완료로 설명하지 않는다.