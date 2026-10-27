---
name: L∞P
description: Existing blue brand for customer tasks and calm operations
colors:
  signal: "#2236c9"
  signal-ink: "#ffffff"
  ink: "#15202b"
  ink-soft: "#526074"
  paper: "#f4f6f8"
  surface: "#ffffff"
  line: "#cbd3df"
  ok: "#10916b"
  warn: "#b86e00"
  danger: "#c0392b"
  ok-bg: "#e7f6f0"
  ok-line: "#b5e2cf"
  ok-ink: "#0b6b4f"
  warn-bg: "#fff4e5"
  warn-line: "#f1c48a"
  warn-ink: "#7a4300"
  danger-bg: "#fdecea"
  danger-line: "#f2b8b1"
  danger-ink: "#9b2c20"
  info-bg: "#eaefff"
  info-line: "#c3cdf7"
  info-ink: "#2236c9"
  bar: "#15202b"
  bar-ink: "#e6ebf1"
  dark-signal: "#7b8cff"
  dark-signal-ink: "#0e141b"
  dark-ink: "#e6ebf1"
  dark-ink-soft: "#9aa8b8"
  dark-paper: "#0e141b"
  dark-surface: "#161e28"
  dark-line: "#2a3644"
typography:
  body:
    fontFamily: "'IBM Plex Sans KR', 'Apple SD Gothic Neo', 'Malgun Gothic', system-ui, sans-serif"
    fontSize: "15px"
    lineHeight: 1.65
  headline:
    fontSize: "clamp(1.5rem, 2.5vw, 2rem)"
    fontWeight: 600
    lineHeight: 1.45
    letterSpacing: "-0.01em"
  title:
    fontSize: "1.5rem"
    fontWeight: 600
    letterSpacing: "-0.01em"
  label:
    fontSize: "0.875rem"
    fontWeight: 500
rounded:
  control: "8px"
  surface: "12px"
  summary: "14px"
  intro: "16px"
  pill: "999px"
spacing:
  compact: "0.5rem"
  base: "1rem"
  panel: "1.25rem"
  section: "2rem"
components:
  button-primary:
    backgroundColor: "{colors.signal}"
    textColor: "{colors.signal-ink}"
    rounded: "{rounded.control}"
    padding: "0.55rem 1rem"
  panel:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.ink}"
    rounded: "{rounded.surface}"
    padding: "1.25rem"
---

# Design System: L∞P

## Overview

기존 L∞P 로고와 루프 블루를 유지한 고객·운영 화면의 실제 구현을 기록한다. 고객 화면은 이용량·요금·자주 찾는 업무를 빠르게 찾는 흐름이며, 운영 화면은 우선 확인할 상태와 목적별 탐색을 중심으로 구성한다. PRODUCT.md는 없으며 이 문서는 제품 약속이나 새로운 브랜드 정체성을 정의하지 않는다.

차분한 중립 배경, 명확한 경계, 짧은 제목과 수치 중심으로 정보 밀도를 조절한다. 본사 사진은 고객 소개와 로그인 보조 영역에 제한되며 가상 이미지임을 표시한다. 설명은 코드에서 추출했으며 별도 사용자 인터뷰로 확정한 새로운 디자인 은유는 없다.

**Key Characteristics:**
- 기존 블루 브랜드와 한국어 산세리프.
- 고객의 반복 업무, 운영자의 우선 상태를 먼저 제시.
- 밝음·어두움 테마의 의미 기반 색상.
- 평면 카드와 명시적인 상태 문구.

## Colors

루프 블루가 주요 행동과 현재 선택을 연결하고 회청색 중립색이 정보 구조를 받친다. 전체 토큰과 테마의 최종 기준은 `frontend/src/styles/global.css`이다. 위 `dark-` 접두사는 같은 CSS 변수의 다크 테마 값이다.

### Primary
- **루프 블루 / signal**: 주요 버튼, 링크, 포커스, 로고 마크, 데이터 링.

### Neutral
- **ink / ink-soft**: 본문과 보조 문구.
- **paper / surface / line**: 페이지, 카드, 구분선.
- **bar / bar-ink**: 관리자 사이드바.

### Status
- `ok`, `warn`, `danger`, `info`와 각 `bg`, `line`, `ink` 조합은 정상·주의·오류·안내를 구분한다. 다크 테마 상태색도 CSS의 대응 변수를 사용한다.
- 심각도는 색상과 함께 글자·아이콘을 제공한다. 기존 카카오 결제 버튼 색상은 기능별 예외이다.

## Typography

본문은 IBM Plex Sans KR와 한국어 시스템 대체 글꼴을 사용한다. 본문 15px, 줄높이 1.65이며 수치는 tabular-nums로 정렬한다. 고객 인사말은 headline, 페이지 제목은 title 토큰을 따른다. 패널 h2는 1rem/600, 큰 데이터 미터 숫자는 3rem/600/1.1이며 860px 이하에서 2.4rem이다. 제목 자간은 -0.01em, 로고와 미터는 -0.02em이다.

## Layout

일반 main은 최대 1240px, 관리자 main은 1400px, 기본 패딩은 2rem이다. 관리자는 224px 고정 사이드바를 사용하고 1024px 이하에서는 192px로 줄인다. 768px 이하에서 사이드바를 숨기고 전체 메뉴를 제공한다. 고객 데스크톱 메뉴도 768px 이하에서 모바일 메뉴로 대체한다.

고객 소개는 3:2 열 비율과 280px 높이 사진을 사용한다. 768px 이하에서는 사진을 숨기고 한 열로 전환한다. 자주 찾는 업무는 다섯 열에서 세 열로, 추천 목록·주의 상태·주요 카드 그리드는 한 열로 전환한다. 표는 가로 스크롤 영역을 유지한다. 기존 1250/1024/960/860/768px 규칙을 함께 확인한다. 이는 코드에 정의된 동작이며 실제 렌더링 검증 결과가 아니다.

## Elevation & Depth

공통 `--shadow`는 두 테마에서 none이다. 카드의 층위는 배경색과 1px 경계로 나타낸다. 펼친 메뉴는 `0 8px 24px rgba(21, 32, 43, 0.12)` 그림자를 사용한다. 선택된 요금제는 2px 색 혼합 링, 선택된 문의는 내부 3px 블루 선으로 표시한다.

## Shapes

입력과 버튼 8px, 일반 패널 12px, 이용 요약 카드 14px, 고객 소개 16px이다. 배지는 999px 캡슐형, 작은 데이터 막대는 2px이다.

## Components

### Buttons

주요 버튼은 signal/signal-ink, 1px 테두리, 최소 높이 44px, 0.55rem 1rem 패딩이다. 작은 버튼과 칩은 최소 40px이다. 보조 버튼은 투명 바탕과 line 테두리를 쓴다. 비활성 버튼은 opacity .6과 progress 커서, hover는 brightness(.96), ghost hover는 강조 테두리를 사용한다.

### Cards / Containers

패널은 surface, line 1px, 12px 모서리, 1.25rem 패딩이다. 요약·바로가기·추천 목록은 목적별 밀도를 유지한다. 운영 우선 상태는 실제 조건에 따라 danger/warn 배경을 쓰며 이름·수치·연결 행동을 함께 표시한다.

### Inputs / Fields

surface 배경, ink 본문, line 1px 경계, 8px 모서리, 0.6rem 0.75rem 패딩을 쓴다. aria-invalid 입력은 danger 테두리와 오류 문구를 사용한다. placeholder는 ink-soft, 커서는 signal이다.

### Navigation

고객은 상단 탐색, 관리자는 고객 업무·보안 관리·관제 도구 그룹의 고정 탐색을 사용한다. 모바일 메뉴에도 역할에 맞는 내부 경로와 관제 도구를 제공한다. 미설정·조회 실패는 문구로 표시한다. 드롭다운은 aria-expanded/aria-controls, 바깥 클릭 닫기, Escape 닫기와 트리거 포커스 복귀를 구현한다. 본문 이동 링크와 3px signal 포커스를 유지한다.

### Data and states

이용량 링은 비율을 0~1로 제한하고 0 분모를 방어한다. 회선 없음·무제한·수집 대기를 구분하며 수집 대기는 문구로 설명한다. 로딩·실패와 재시도·빈 목록을 유지한다. 운영 조회 시각은 화면 렌더 시각이며 실시간 갱신 보증이 아니다. Zabbix 패널과 기존 API·권한 경계를 유지한다.

## Do's and Don'ts

### Do:
- **Do** 기존 의미 토큰과 두 테마를 함께 사용한다.
- **Do** 상태를 글자와 행동으로 설명하고 경고색은 실제 조건에 연결한다.
- **Do** 가상 본사 표기, 모바일 경로, Escape 처리와 본문 이동 링크를 보존한다.

### Don't:
- **Don't** 새 브랜드 색상이나 제품 성능 주장을 만들지 않는다.
- **Don't** 장식 사진을 실제 이용 정보보다 크게 확대하지 않는다.
- **Don't** 데이터 미수집을 정상 수치로 꾸미거나 조회 시각을 실시간 보장으로 설명하지 않는다.
- **Don't** 디자인 변경을 위해 API·인증·인가·Zabbix 계약을 바꾸지 않는다.
