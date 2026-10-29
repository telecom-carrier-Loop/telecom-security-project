# 공개 HTTPS 진입점 — HAProxy 적용 현황과 절차

2026-10-28 정리. **HAProxy 설치·11443 시험·운영443 전환을 사용자 화면으로 확인했다.** 아래 현재 상태가 우선하며, 이후 번호별 절차는 적용 방법과 복구 참고다. 문서 작성 환경에서 학원 서버에 직접 접속해 검증한 결과는 아니다.

## 확인된 현재 상태

| 항목 | 확인 결과 |
|---|---|
| HAProxy | 2.8.3-86e043a, PC3 pfSense에서 실행 |
| 공통 Backend | telecom-public-nodes, pc1-web 192.168.7.185:30443 / pc2-web 192.168.7.100:30443, 둘 다 Active/UP |
| 시험 Frontend | telecom-public-test, 192.168.3.30:11443, TCP/TLS 통과 |
| 운영 Frontend | telecom-public-https, 192.168.3.30:443, TCP/TLS 통과. Sessions Total=1 화면 확인 |
| 이전 운영 NAT | telecom-service-https(.3.30:443→.7.185:30443)는 비활성화, 삭제하지 않음 |
| 운영 WAN 허용 | telecom-haproxy-public-443, 원본192.168.3.0/24→192.168.3.30:443 |
| 관리 GUI | nginx의 IPv4/IPv6 8444 리스닝 확인, LAN 관리 주소 https://192.168.50.1:8444 |
| Stats | 내부 포트2200 설정 절차 후 표시 성공. 2200 WAN 공개는 불필요 |
| 11443 시험 | readiness30/30 HTTP200/CurlExit0, 관리자 데이터 표시, 양 backend 세션17/17 |
| PC1 수동 제외 | pc1-web MAINT 중 누계17 유지, pc2-web 17→47, 요청30/30 성공. 이후 양쪽 UP |
| 443 시험 | readiness HTTP200/database ok와 운영 Frontend 누계 증가 확인. 전환 후30회·양쪽 분산·역할별 회귀는 미확인 |
| 자동 DOWN 시험 | 닫힌30446과 Runtime API 포트 변경까지 확인. DOWN 화면·전환 중 연속요청 결과는 미확인 |
| 시험 후 복구 | 실행 중 pc1-web port/check_port=30443 및11443 readiness200 확인. GUI 저장값도30443인지 유지 확인 필요 |

근거와 한계는 [HAProxy 현장 적용 기록](../operations/2026-10-28-haproxy-public-cutover.md)에 모았다. 후속 [HTTP→HTTPS 자동 이동](academy-http-https-redirect.md)은 아직 적용하지 않았다. 첨부 화면의 서버 Date가10월27일인 항목은 촬영일을10월28일로 재단정하지 않는다.

## 범위와 전제

- 적용 전 기준 상태: 공개443 고정NAT→PC1:30443. 이후 위 현재 상태처럼 HAProxy 운영443으로 전환했다. 양쪽NodePort 직접 HTTPS200, API요청30회 양노드분산, API Pod1개종료 중60회200은 앞선 별도 시험이다.
- 현재 구성은 PC3에서 양 노드의 TCP 연결 상태를 감시한다. 실제 실패 자동 제외·복귀의 현장 증거는 추가 확보해야 한다.
- 1단계는 별도 시험포트 `192.168.3.30:11443`을 사용한다. 기존443 NAT를 이 단계에서 변경하지 않는다. 11443은 사용 중인 규칙/listener가 없는지 먼저 확인한다.
- n8n10443은 담당자와 확인할 별도 경로이며 이번 전환에 포함하지 않았다. 기존9443도 유지했다.
- TLS는 기존 k3s edge에서 종료하는 TCP 통과 방식으로 시작한다. 브라우저가 기존.3.30 인증서를 검증하므로 이 단계에 인증서 개인키를 pfSense로 복사할 필요가 없다.
- 이 진입점만 보완해도 Primary DB/단일제어부 문제는 남는다. PC1전체장애를 자동승계한다고 판정하지 않는다.

## 1. PC3 pfSense 백업·설치 확인

1. Diagnostics → Backup & Restore에서 현재 설정을 비공개 로컬 경로에 저장한다. 설정XML에는 자격증명이 포함될 수 있으므로 공개Git에 올리지 않는다.
2. System → Package Manager → Installed Packages에서 haproxy 또는 haproxy-devel과 버전을 확인한다.
3. 이미 설치돼 있으면 중복설치하지 않는다. 없으면 Available Packages에서 **haproxy 안정판**을 검색해 Install → Confirm으로 설치한다.
4. 설치오류/패키지목록 불러오기 오류가 나면 그 오류부터 진단한다. 임의OS업그레이드·외부설치스크립트·수동pkg저장소변경으로 우회하지 않는다.
5. Services → HAProxy 메뉴가 보이는지 확인한다. 최초 설정 화면/Backend Add 화면을 기준으로 다음 필드를 맞춘다. 아직Enable만 켜서 빈설정을 시작하거나 기존NAT를 삭제하지 않는다.

## 2. 준비할 공개용 Backend — 설치 확인 후

실제 GUI 명칭은 패키지 버전에 맞춘다. 아래는 적용 기준이며 각 항목의 관측 결과는 상단 현재 상태를 따른다.

| 항목 | 값 |
|---|---|
| Backend 이름 | telecom-public-nodes |
| Balance | Round robin |
| 서버1 Mode / Name | Active / pc1-web |
| 서버1 Address / Port | 192.168.7.185 / 30443 |
| 서버2 Mode / Name | Active / pc2-web |
| 서버2 Address / Port | 192.168.7.100 / 30443 |
| 서버 SSL 암호화 옵션 | 해제: 이미 암호화된 TLS 스트림을 통과시키며 다시 감싸지 않음 |
| Send PROXY protocol | 해제: 현재Nginx listen은 PROXY protocol 수신 설정이 아님 |
| Cookie persistence / stick table | 초기시험에서는 추가하지 않음 |
| 기본 Health check | Basic/TCP 계열, 주기2000ms를 명시(실제 UI 확인) |
| Transparent client IP | 초기시험에서는 사용하지 않음 |

TCP check는 접속 포트의 생존 여부를 검사한다. HTTP/API/DB 정상까지 입증하지 않으므로 HTTPS readiness와 함께 확인한다. 최종 장애 판정 범위를 넓히려면 체크용 SSL과 `/edge-health` 응답 검사 등을 실제 패키지 지원 옵션에 맞춰 보완한다. 공유 DB 장애를 VIP/노드 선택의 유일한 기준으로 삼지 않는다.

양쪽 서버를 Active로 두면 정상일 때 둘 다 사용한다. PC2를 Backup으로 두는 구성은 정상 트래픽 분산과 동작이 다르므로 현재 목표와 구분한다.

## 3. 시험용 Frontend·WAN 허용 — Backend 확인 후

| 항목 | 값 |
|---|---|
| Frontend 이름 | telecom-public-test |
| Listen 주소 | 192.168.3.30 한 주소만 |
| Listen port | 11443 |
| Type / Mode | TCP 또는 ssl/https(TCP mode), 실제 UI 확인 |
| SSL offloading | 해제 |
| Default backend | telecom-public-nodes |
| HTTP redirect/ACL/header 설정 | 초기TCP통과시험에는 추가하지 않음 |

Firewall → Rules → WAN에는 출발지 `192.168.3.0/24`, 목적지 `192.168.3.30:11443`, IPv4/TCP Pass와 Log를 별도로 준비한다. Gateway는 default, 같은 인터페이스로 돌아오는 경로는 기존 경로처럼 Disable reply-to를 확인한다. 이 listener에는 Port Forward를 추가하지 않는다. 같은 포트의 NAT가 있다면 먼저 충돌을 해결한다.

유효한 Frontend/Backend를 완성한 후 Settings의 Enable과 필수 최대 연결 수를 실제 UI에 맞춰 저장하고 검증/Apply한다. 설정 검사 오류가 나면 운영443을 전환하지 않는다. Stats/관리 화면을 WAN 전체에 공개하지 않는다.

## 4. 시험 포트 확인 — 실제 적용 후에만

프로젝트 CA를 신뢰한 PC2 Windows에서 실행한다.

```powershell
Test-NetConnection 192.168.3.30 -Port 11443
curl.exe --noproxy '*' --ssl-revoke-best-effort --connect-timeout 3 --max-time 10 -sS -i 'https://192.168.3.30:11443/edge-health'
curl.exe --noproxy '*' --ssl-revoke-best-effort --connect-timeout 3 --max-time 10 -sS -i 'https://192.168.3.30:11443/api/health/ready'
```

기대값은 TCP True, edge-health200, readiness200/database ok다. HAProxy 통계에서 두 backend가 UP인지 확인한다. 현장에서는11443 관리자 로그인·대시보드 조회도 성공했다. 업무 쓰기 전체 또는 운영443 역할별 회귀까지 성공했다고 확대하지 않는다.

Backend가 DOWN이면 HAProxy의 실제 송신 IP/경로와 NodePort 접근, Service Local/Pod 배치를 확인한다. TCP 통과 모드에서 SSL 재암호화/PROXY protocol이 잘못 켜지면 TLS/HTTP가 깨질 수 있다.

## 5. 운영443 전환·복구 절차

1. 시험 포트 성공과 현재 설정 백업을 확인한다.
2. HAProxy 운영 Frontend를 `.3.30:443`용으로 준비한다. 기존 NAT/관리 GUI와 충돌하지 않는지 확인한다.
3. `.3.30:443 → .7.185:30443` 기존 Port Forward와 연동 규칙을 구분해 전환한다. WAN에 HAProxy 자체로 들어오는 `.3.30:443` Pass 규칙이 필요하다. NAT 변환 후 목적지 `.7.185:30443` 규칙만 남기면 충분하지 않다.
4. 전환 전후 같은 주소의 TLS·readiness·고객/ADMIN 로그인·미인증401/CUSTOMER403·공개 internal404를 회귀 확인한다. 기존 TCP 연결은 새 backend로 중간 이동하지 않으며 클라이언트 재연결을 포함해 관측한다.
5. 오류면 이번 운영 Frontend를 비활성화하고 기존443 NAT/연동 규칙을 복구한다. 필요한 연결 state만 대상별로 정리하며 전체 state 초기화는 하지 않는다.
6. 양 backend 연결/장애 제외를 측정한 후 VM 중단 시험 범위를 정한다. PC1 전체 중단 전에는 DB와 제어부 보완이 별도로 필요하다.

## 상태 파일로 인해 변경 전 포트가 남았을 때

현장에서 생성된 설정의PC1포트는30446인데 실행 중 포트는30443인 상태를 확인했다. `server-state-file /tmp/haproxy_server_state`와 `load-server-state-from-file global`이 있었고 저장 파일에도30443이 남아 있었다. 재적용 시 이전 서버 포트가 복원된 정황이며 화면값만으로 실행 포트를 판단하지 않는다.

아래 조회는 pfSense Shell에서 실행한다. 서버 번호·이름은 실행 결과를 기준으로 하며 #100/#101을 모든 환경의 고정값으로 사용하지 않는다.

```sh
printf 'show servers state\n' | nc -N -w 2 -U /tmp/haproxy.socket
```

당시 backend ID100, PC1 server ID101이었다. 명령에서 `ipvANY`를`ipANY`로 쓰거나 서버번호의`#`을 생략하면 No such backend/server가 발생했다. Runtime API에서 목적지 포트와 검사 포트는 각각 확인해야 한다. 한쪽만30443으로 복구하면 실제 전달은 실패하는데 건강검사만UP일 수 있다.

최종 복구 기준은 **실행 목적지30443, 검사포트30443(또는 서버포트를 따르는0), GUI 저장포트30443, 두서버UP, HTTPS readiness200**이다. Runtime API 변경은 시험용이며 상태파일 삭제·전체서비스 재시작으로 무작정 해결하지 않는다.

## 근거

- [Netgate HAProxy 패키지](https://docs.netgate.com/pfsense/en/latest/packages/haproxy.html)
- [Netgate HAProxy 진단](https://docs.netgate.com/pfsense/en/latest/troubleshooting/haproxy.html)
- [pfSense HAProxy Backend UI 원본](https://github.com/pfsense/FreeBSD-ports/blob/devel/net/pfSense-pkg-haproxy/files/usr/local/www/haproxy/haproxy_pool_edit.php): 서버 SSL과 SSL 체크의 차이, Active/Backup, TCP 체크 주기 필드.
- [현재 이중화 현황·실측](academy-ha-assessment.md)
