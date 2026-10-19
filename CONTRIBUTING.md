# 협업 기준

정본은 [통합 확정 기준](docs/contracts/integration-baseline-v1.0.md)입니다.

## 브랜치

- `main`: 검증된 안정 버전.
- `develop`: 공동 통합.
- 작업은 최신 `develop`에서 시작합니다. Codex 작업은 `codex/a-*`, `codex/b-*`, `codex/c-*`, `codex/d-*`를 사용합니다. 팀원이 수동으로 만드는 작업 브랜치는 기존 `feature/*`, `infra/*`, `security/*`, `monitor/*`, `fix/*`, `test/*`, `docs/*`를 사용할 수 있습니다.
- 저장소 최초 초기화만 main에 기본 구조를 넣습니다. 이후 main/develop 직접 push는 사용하지 않습니다. 이 규칙의 문서화가 GitHub 보호 규칙 설정을 의미하지는 않습니다.

## 커밋·PR

사용자 본인의 GitHub 계정을 author로 사용하고 한 작업씩 나눕니다. 커밋과 PR 제목은 한글 `<type>(<scope>) : <요약>`으로 작성합니다.

타입: feat, fix, build, chore, ci, docs, style, refactor, test, perf.

```text
feat(auth) : DB 공유 세션 로그인 구현
fix(network) : API NodePort를 30500으로 통일
docs(contract) : 인시던트 이벤트 규격 작성
```

공통 API·환경변수·포트·라벨·로그 변경은 계약·샘플·관련 검증을 함께 갱신합니다. 영향받는 분야 담당자가 확인한 뒤 PR을 통합합니다. CODEOWNERS와 강제 PR 본문 양식은 추가하지 않습니다.

## 변경 경계

A가 공통 라우터·인증·앱 초기화·모델 등록·패키지/잠금 파일을 통합합니다. B는 실행·배포, C는 네트워크 정책, D는 관제·자동화를 소유합니다. 공통 파일을 동시에 수정할 때 Issue에서 파일 범위를 나눕니다.

## 검증·민감정보

바꾼 부분의 정상·오류 경로를 확인하고 환경·Commit·예상/실제 결과를 남깁니다. 설계·로컬 검증·공용 PC 실증을 구분합니다. `.env`, 비밀번호, 인증서 개인키, VPN 프로필, kubeconfig, 토큰, Discord URL, 실제 DB 덤프와 생 로그는 업로드하지 않습니다.
