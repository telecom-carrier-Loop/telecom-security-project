# 공개 HTTPS 진입점 이중화 — HAProxy 단계별 준비

2026-10-27 계획. **아래 HAProxy 구성은 아직 현장 적용하지 않았다.** 사용자 확인 상태는 패키지 설치 여부 미확인이다. 먼저 설치 여부/버전을 확인하고 실제 화면과 맞춰 적용한다.

## 범위와 전제

- 현재 정상 상태: 공개443 고정NAT→PC1:30443, 양쪽NodePort 직접 HTTPS200, API요청30회 양노드분산, API Pod1개종료 중60회 모두200 및 대체Pod복구.
- 다음 목표: PC3에서 PC1/PC2의 공개 HTTPS endpoint를 상태 감시하고 새 연결을 정상 노드에 전달한다.
- 1단계는 별도 시험포트 `192.168.3.30:11443`을 사용한다. 기존443 NAT를 이 단계에서 변경하지 않는다. 11443은 사용 중인 규칙/listener가 없는지 먼저 확인한다.
- n8n10443은 내일 담당자와 확인할 별도 경로이며 지금 함께 변경하지 않는다. 기존9443도 별도 검토 전까지 유지한다.
- TLS는 기존 k3s edge에서 종료하는 TCP 통과 방식으로 시작한다. 브라우저가 기존.3.30 인증서를 검증하므로 이 단계에 인증서 개인키를 pfSense로 복사할 필요가 없다.
- 이 진입점만 보완해도 Primary DB/단일제어부 문제는 남는다. PC1전체장애를 자동승계한다고 판정하지 않는다.

## 1. PC3 pfSense 백업·설치 확인

1. Diagnostics → Backup & Restore에서 현재 설정을 비공개 로컬 경로에 저장한다. 설정XML에는 자격증명이 포함될 수 있으므로 공개Git에 올리지 않는다.
2. System → Package Manager → Installed Packages에서 haproxy 또는 haproxy-devel과 버전을 확인한다.
3. 이미 설치돼 있으면 중복설치하지 않는다. 없으면 Available Packages에서 **haproxy 안정판**을 검색해 Install → Confirm으로 설치한다.
4. 설치오류/패키지목록 불러오기 오류가 나면 그 오류부터 진단한다. 임의OS업그레이드·외부설치스크립트·수동pkg저장소변경으로 우회하지 않는다.
5. Services → HAProxy 메뉴가 보이는지 확인한다. 최초 설정 화면/Backend Add 화면을 기준으로 다음 필드를 맞춘다. 아직Enable만 켜서 빈설정을 시작하거나 기존NAT를 삭제하지 않는다.

## 2. 준비할 공개용 Backend — 설치 확인 후

실제 GUI 명칭은 패키지 버전에 맞춘다. 아래는 설정할 값이며 적용 완료 기록이 아니다.

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

기대값은 TCP True, edge-health200, readiness200/database ok다. HAProxy 통계에서 두 backend가 UP인지 확인한다. 시험 포트에서는 이 상태 조회만 진행하고 로그인/업무 쓰기 결과를 운영443과 같다고 가정하지 않는다.

Backend가 DOWN이면 HAProxy의 실제 송신 IP/경로와 NodePort 접근, Service Local/Pod 배치를 확인한다. TCP 통과 모드에서 SSL 재암호화/PROXY protocol이 잘못 켜지면 TLS/HTTP가 깨질 수 있다.

## 5. 운영443 전환은 시험 포트 검증 후 별도 진행

1. 시험 포트 성공과 현재 설정 백업을 확인한다.
2. HAProxy 운영 Frontend를 `.3.30:443`용으로 준비한다. 기존 NAT/관리 GUI와 충돌하지 않는지 확인한다.
3. `.3.30:443 → .7.185:30443` 기존 Port Forward와 연동 규칙을 구분해 전환한다. WAN에 HAProxy 자체로 들어오는 `.3.30:443` Pass 규칙이 필요하다. NAT 변환 후 목적지 `.7.185:30443` 규칙만 남기면 충분하지 않다.
4. 전환 전후 같은 주소의 TLS·readiness·고객/ADMIN 로그인·미인증401/CUSTOMER403·공개 internal404를 회귀 확인한다. 기존 TCP 연결은 새 backend로 중간 이동하지 않으며 클라이언트 재연결을 포함해 관측한다.
5. 오류면 이번 운영 Frontend를 비활성화하고 기존443 NAT/연동 규칙을 복구한다. 필요한 연결 state만 대상별로 정리하며 전체 state 초기화는 하지 않는다.
6. 양 backend 연결/장애 제외를 측정한 후 VM 중단 시험 범위를 정한다. PC1 전체 중단 전에는 DB와 제어부 보완이 별도로 필요하다.

## 근거

- [Netgate HAProxy 패키지](https://docs.netgate.com/pfsense/en/latest/packages/haproxy.html)
- [Netgate HAProxy 진단](https://docs.netgate.com/pfsense/en/latest/troubleshooting/haproxy.html)
- [pfSense HAProxy Backend UI 원본](https://github.com/pfsense/FreeBSD-ports/blob/devel/net/pfSense-pkg-haproxy/files/usr/local/www/haproxy/haproxy_pool_edit.php): 서버 SSL과 SSL 체크의 차이, Active/Backup, TCP 체크 주기 필드.
- [현재 이중화 현황·실측](academy-ha-assessment.md)
