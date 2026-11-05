# 2026-11-05 실제 출발지 전달 적용·검증 인계

작성 기준: 사용자 실행 결과와 제공된 API/Wazuh 로그. 이 문서의 결과는 실행 중인 환경을 도구가 직접 재조회해 확인한 기록이 아니다. 실제 주소·원시 로그·pfSense 전체 백업·토큰·인증서 파일은 비공개 자료로 관리한다.

## 수행 내용

공개 HTTPS의 HAProxy TCP 전달은 유지하면서 PROXY v2용 Backend와 별도 k3s edge를 준비했다. `telecom-edge-proxytest` 두 Pod는 PC1/PC2에 각각 배치됐고, NodePort 31443에서 TLS/PROXY listener 8445로 연결했다. 기존 8443 probe, 노드 로컬 Web/API upstream, TLS 참조 및 공개 관리자/내부 API 404를 보존했다.

사용자가 계획의 양 노드 `nginx -t`·서버 dry-run 통과와 생성 후 두 Pod Running/Ready 결과를 전달했다. pfSense 시험 Backend 두 서버 UP과 시험 11443의 고객/준비 상태/보호 경로 응답을 확인한 뒤 공개 443을 새 Backend로 전환하는 절차를 진행했다.

## 확인한 결과와 한계

| 항목 | 사용자 제공 근거와 판정 |
|---|---|
| 시험 11443 | 고객 `/`·준비 API 200, 관리자 UI/API·내부 API 404 |
| 정식 443 준비 상태 | 200, database/status ok. 끝에 `/`가 추가된 다른 경로의 404와 구분 |
| 정식 443 가상 계정 로그인 실패 | 401 INVALID_CREDENTIALS |
| Nginx와 API 출발지 | pfSense 공통 주소 대신 관측된 Windows NAT 주소 |
| API의 두 이벤트 | 같은 요청 ID의 auth.login.failed/http.request에 동일 src_ip |
| Wazuh 로그인 수집 | API와 동일 event_id·발생 시각·src_ip의 login-bruteforce/http-access, 룰 110684 |
| 별도 Kali VM | 독립 주소 확인. 기존 WAN 허용 범위에 없음을 백업에서 확인해 해당 호스트→공개 443만 허용하는 규칙 안내. 사용자는 이후 실습 완료를 보고 |
| 별도 Kali 자동 차단 | 구체적인 n8n 실행·차단 API 응답·새 요청 IP_BLOCKED 증거는 이 대화에서 받지 못함 |

Wazuh 변환 이벤트에는 원래 request_id가 없어 첫 검색이 비어 있었다. 원본 event_id와 시각을 대조하여 같은 로그인 실패의 수집임을 확인했다. 110684 수집 경보를 반복 공격 집계 룰 발동이나 Discord·자동 조치 성공으로 해석하지 않는다.

WSL 출발지는 Windows NAT 주소로 관측됐고 현재 n8n 보호 IP 목록에 포함돼 있다. 이를 임의 해제하지 않고 별도 Kali VM 주소로 차단 시연을 분리하도록 안내했다. n8n 설정 변경본이나 HTTP 요청량 자동 차단 활성화는 이 PR에 포함하지 않는다.

## 인계 및 남은 확인

- 이미 존재하는 시험 이름은 현재 공개 트래픽을 처리할 수 있으므로 삭제하거나 생성 도구를 재실행하지 않는다.
- 다음 릴리스부터 새 edge도 검사하는 동일 커밋의 도구 패키지를 사용한다. 저장소 병합은 실행 중인 서버에 자동 적용되지 않는다.
- 별도 Kali IP가 API→Wazuh→n8n까지 유지되는지, 보호/임계값 조건, 실제 차단 요청과 후속 IP_BLOCKED를 대조한다.
- 관리 전용 입구·자동화 입구·기존 로그인/업무·관제 파이프라인, 장애 전환/재부팅/복구는 이 변경 이후의 회귀 검증을 추가한다.
- 공개 443의 실제 Default Backend와 변경 후 pfSense 백업을 비공개 인계에 기록한다. 이 PR의 릴리스 검사는 pfSense 활성 구성을 자동 조회하지 않는다.

[설정·검증·복구 절차](../runbooks/academy-client-ip-preservation.md)
