# 프론트엔드 — A

React + Vite + TypeScript, Node.js 22 계열을 사용합니다. 현재 폴더 구조만 있으며 앱·package.json·lock 파일은 A의 첫 기능 PR에서 추가합니다.

- `src/app/`: 공통 라우팅·Provider.
- `src/features/`: auth, dashboard, plans, support, membership, payments, incidents.
- `src/components/`: 공통·레이아웃·UI, `src/services/`: API 연결, `src/styles/`: 공통 스타일.
- 브라우저 API 주소는 `/api` 상대 경로만 사용합니다. Secret을 Vite 변수에 넣지 않습니다.
- 고객 문의는 C, 인시던트는 D와 기능별 파일을 나눕니다. 공통 파일은 A가 통합합니다.
- Dockerfile은 `../infrastructure/docker/frontend/Dockerfile`에 작성하며 컨텍스트는 이 폴더입니다.

[API 계약](../docs/contracts/api-common.md) · [인증 계약](../docs/contracts/auth-api.md)
