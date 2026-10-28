# 문서 안내

- contracts/: 공통 개발 기준, 실행·API·환경변수·네트워크·이벤트 계약.
- architecture/: 서비스 배치·ERD·의존성·위험·용량 계획.
- api/: 계약을 바탕으로 생성할 API 참조·사용 예시. 계약을 중복 정의하지 않습니다.
- threat-model/: 위협 모델.
- security/: 시나리오 결과와 보안 요약.
- meeting-notes/: 날짜·담당·결정·Issue/PR 링크.

[통합 개발 확정 기준](contracts/integration-baseline-v1.0.md)을 먼저 읽고, 변경한 계약과 설정·테스트를 함께 갱신합니다.

## 최신 현장 기록

- [PC2 Primary 예약 백업·Discord 감시: 기존 작업 유지와 비활성 준비 절차](runbooks/mysql84-primary-schedule.md)

- [2026-10-28 PC2 앱 계정·제한접속·25개테이블 복원 확인과 Primary 백업 모드 준비](runbooks/mysql84-primary-backup.md)

- [2026-10-28 정리: HAProxy 시험 결과·운영443 전환·남은 검증](operations/2026-10-28-haproxy-public-cutover.md)
- [이중화 현황: 요청 분산·공개 진입점 적용과 PC1 전체 장애 대응의 미완성 항목](runbooks/academy-ha-assessment.md)
- [공개 HTTPS HAProxy: 적용 현황·시험·운영 전환·포트 복구](runbooks/academy-haproxy-public-ingress.md)
- [다음 단계: HTTP→HTTPS 자동 이동 — 아직 미적용](runbooks/academy-http-https-redirect.md)
- [2026-10-27 자동화 API 입구 배포·PC2 미인증401 확인 및 n8n 담당자 인계](operations/2026-10-27-automation-ingress-handoff.md)
- [2026-10-27 DB 보안 후속 인계: webuser·PC1 적용 보고·PC2 및 파트별 검증](operations/2026-10-27-db-security-handoff.md)
- [2026-10-27 웹·DB 복제·백업 복구와 프론트엔드 재배포](operations/2026-10-27-service-recovery.md)
- [학원망 공통 HTTPS 주소의 ADMIN 권한 기반 접근 전환 도구·절차 — 현장 적용 전](runbooks/academy-admin-access.md)
- [MySQL 사용자 PC 직접 접근 제한·앱 계정 분리 — 현장 사전 점검](runbooks/mysql-network-access-hardening.md)
- [보고서 기반 Windows DB 포트 제한 도구와 PC1→PC2 적용·복구](runbooks/mysql-firewall-scope.md)
- [2026-10-26 후속: 서비스 IP·인증서 적용 진행과 스위치 재연결 후 VM 네트워크 복구 중](operations/2026-10-26-network-recovery.md)
- [2026-10-26 pfSense HTTPS·관리자 접속 구성과 학원망 장애 인계: 미해결 ARP·반환 경로·서비스 IP 계획](operations/2026-10-26-pfsense-https-access.md)
- [2026-10-25 인프라 후속 정리: k3s HTTPS·격리 복원·백업 Discord 감시·재배포 확인](operations/2026-10-25-infra-status.md)
- [2026-10-23 학원망·VLAN 미분리·VM k3s 구성도](../network/diagrams/academy-k3s-20261023.md)
- [구성도 변경의 저장소 분석 근거와 남은 검증](architecture/academy-network-20261023.md)
- [2026-10-22 k3s 웹 배포·검증 결과와 pfSense 인계](operations/2026-10-22-k3s-web-handoff.md)
- [MySQL 복제·백업·복구의 k3s 이전 영향 점검](runbooks/mysql84-k3s-impact.md)
