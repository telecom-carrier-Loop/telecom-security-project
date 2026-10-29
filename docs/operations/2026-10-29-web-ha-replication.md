# 10월 29일 웹 이중화와 DB 복제 현장 기록

사용자가 제공한 화면을 기준으로 정리했다. 현장에 직접 접속한 결과는 아니다. 비밀번호, 인증서 개인키와 백업 원본은 포함하지 않는다.

## DB 현재 역할

- PC2 `192.168.3.19`의 MySQL은 server_id 2, read_only 0, super_read_only 0인 Primary다. 두 API는 PC2 DB를 사용한다.
- PC1 `192.168.3.18`의 MySQL은 server_id 1, read_only 1, super_read_only 1인 Replica다. `pc2_to_pc1` 채널에서 IO/SQL 실행과 TLS 서버 인증서 검증을 확인했다.
- PC1 MySQL 재시작 후 복제 자동 재개와 두 복제 스레드 정상 작동을 확인했다. PC2에서 가져온 두 UUID의 GTID 검사에서 PC1 `WAIT_FOR_EXECUTED_GTID_SET` 결과가 0이었다. 해당 시점 이후 신규 쓰기까지 확인한 결과는 아니다.
- PC2 Primary 예약 백업과 Discord 감시는 활성화되어 있고 기존 Replica 작업은 비활성이다. 예약 백업 성공과 25개 테이블 격리 복원 시험을 확인했다. 백업은 현재 PC2에 있다.
- 자동 승격과 자동 원복은 구축 여부를 확인하지 못했다. 양쪽 DB를 동시에 쓰기 가능하게 만들지 않는다.

## 웹 진입과 DNS

- PC1·PC2 노드 Ready, 공개 edge·API·Web이 각각 두 Pod로 노드별 배치된 화면을 확인했다.
- CoreDNS를 두 개로 변경하고 노드 간 분산 배치했다. rollout 성공, 두 API Pod에서 API/Web 서비스 이름 조회 성공을 확인했다. 배포 재적용·업그레이드 후 유지 여부는 아직 확인하지 않았다.
- 공개 `telecom-edge`의 `externalTrafficPolicy`는 Local이다. 각 노드의 30443 직접 HTTPS 및 공개 HTTPS에서 readiness 200과 database ok를 확인했다. API·Web 서비스의 `internalTrafficPolicy`는 Cluster다.
- 공개 HAProxy는 `192.168.3.30:443`에서 TLS를 통과시켜 두 노드의 30443으로 전달한다. 두 Backend의 HTTPS `/edge-health` 검사는 UP, L7OK/200이었다. 공개 `/edge-health`와 API readiness도 200이었다. edge 검사는 API나 DB의 독립적인 정상 보장을 뜻하지 않는다.
- 설정 중 CoreDNS 교체 시 일시적인 스케줄 및 준비 경고가 있었지만 이후 두 Pod의 1/1 정상 상태를 확인했다.

## 후속 시험과 남은 제한

1. HAProxy 건강검사의 자동 DOWN, PC2 처리, 복구 후 자동 UP을 측정한다. 이전 MAINT 시험은 수동 제외였다. 공개 443과 시험 11443은 같은 Backend를 사용하므로 시험이 운영 경로에도 영향을 준다.
2. 시험 전 두 Backend의 현재 대상·검사 포트, 설정과 실행 상태, PC2 readiness, 복구 절차를 확인한다. 시험 결과와 실패 횟수·시간을 기록한다. 실제 서버를 끄거나 DB 역할을 바꾸는 시험과 구분한다.
3. PC1 VM 전체 장애 시 내부 Service의 기존 endpoint, CoreDNS, 연결과 API 쓰기를 별도로 검증한다. API·Web의 Cluster 정책은 노드 간 전달을 허용한다. Local로 변경하면 해당 노드에 준비된 Pod가 없을 때 연결이 실패할 수 있으므로 일괄 변경하지 않는다.
4. PC1은 유일한 k3s control plane이다. 현재 PC1 물리 장애 시 클러스터 관리 및 새로운 스케줄링의 고가용성은 확인되지 않았다. PC3 pfSense 역시 단일 진입점이다.
5. PC1 Replica의 백업, n8n 전용 10443 경로와 담당자의 실제 이벤트 검증, 일반 PC 차단, PC2 Primary 백업의 외부 사본을 후속 확인한다.

이 문서는 구성·시험 결과를 기록하며 현장 설정을 변경하지 않는다.

## 추가 확인과 작업 종료

- HAProxy PC1 건강검사 포트를 일시적으로 30446으로 변경한 시험에서 Dwn 누계가 1에서 2로 증가했고, 복구 후 두 서버가 UP / L7OK 200이었다. 60회 관찰 요청은 모두 HTTP 200, curl 종료 코드 0이었다. 실제 PC1 VM 장애나 자동 DB 승격 시험은 아니다.
- 복구 후 pc1-web의 실제 전달 포트와 검사 포트가 모두 30443임을 확인했다. PC2의 Primary 백업·감시 작업은 Ready였고, 기존 Replica 작업은 Disabled였다.
- PC1 Ubuntu에서 공개 443 연결 실패는 pfSense WAN 기본 차단 로그로 확인했다. PC1 VM의 제한된 접근 허용 이후 CA 검증을 사용하는 공개 readiness가 200 / database ok였다. PC2 Windows에서도 200을 확인했다.
- PC1 Ubuntu VM 중단 시험을 시작하려던 중 컴퓨터가 꺼졌다고 사용자가 보고했다. 종료 대상, 시험 명령 실행 여부, 정상 종료 여부 및 종료 후 DB·클러스터 상태는 확인되지 않았다. 시험 완료나 자동 전환 성공으로 기록하지 않는다.
- 다음 시작 때 전원을 켠 후 PC2 Primary·PC1 읽기 전용과 복제 채널, API 실제 DB 대상, 예약 백업 결과, VM IP·k3s·CoreDNS·HAProxy 및 공개 readiness를 순서대로 확인한다. 장애 원인을 단정하거나 DB 승격, 복제 초기화, 무분별한 재배포를 하지 않는다.
- 이전 지침의 90회 요청은 각 요청 시간 초과가 더해질 수 있어 90초 내 종료를 보장하지 않는다. 중단 시험은 재기동 수단 및 운영 중단 범위를 먼저 확인한 뒤 별도로 계획한다.
