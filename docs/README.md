# 문서 안내

- contracts/: 공통 개발 기준, 실행·API·환경변수·네트워크·이벤트 계약.
- architecture/: 서비스 배치·ERD·의존성·위험·용량 계획.
- api/: 계약을 바탕으로 생성할 API 참조·사용 예시. 계약을 중복 정의하지 않습니다.
- threat-model/: 위협 모델.
- security/: 시나리오 결과와 보안 요약.
- meeting-notes/: 날짜·담당·결정·Issue/PR 링크.

[통합 개발 확정 기준](contracts/integration-baseline-v1.0.md)을 먼저 읽고, 변경한 계약과 설정·테스트를 함께 갱신합니다.

## 최신 현장 기록

- [2026-10-22 k3s 웹 배포·검증 결과와 pfSense 인계](operations/2026-10-22-k3s-web-handoff.md)
- [MySQL 복제·백업·복구의 k3s 이전 영향 점검](runbooks/mysql84-k3s-impact.md)
