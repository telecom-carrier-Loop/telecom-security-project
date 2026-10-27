# HAProxy 현장 시험과 운영 HTTPS 전환 기록

정리일: 2026-10-28 Asia/Seoul. 사용자 제공 화면을 근거로 기록했다. 일부HTTP응답의서버Date는10월27일이므로 정리일을전체시험수행일로간주하지 않는다. 설정XML·토큰·개인키·세션정보는첨부하지 않는다.

## 현재 서비스 경로

```text
학원 사용자(192.168.3.0/24)
  → https://192.168.3.30:443
  → PC3 pfSense WAN 허용 규칙
  → HAProxy telecom-public-https (TCP/TLS 통과)
  → telecom-public-nodes
      pc1-web 192.168.7.185:30443
      pc2-web 192.168.7.100:30443
  → k3s edge → telecom-web / telecom-api
  → PC1 Windows MySQL Primary 192.168.3.18:3306
```

TLS는k3s edge에서종료한다. HAProxy의SSL offloading과서버Encrypt(SSL)은꺼져있다. 일반웹사용자에게MySQL포트를공개하는변경은없다.

## 확인 결과

| 시험/변경 | 화면에서 확인한 결과 | 판정 범위 |
|---|---|---|
| HAProxy 설치 | 2.8.3-86e043a | 패키지실행확인 |
| 11443 edge/API | edge-ok, readiness200/database ok | TLS·API·DB조회성공 |
| 11443 연속요청 | 30/30 HTTP200, CurlExit0 | 관측표본성공 |
| 11443 관리자 | 관리자대시보드데이터표시 | ADMIN조회성공, 전체쓰기검증아님 |
| 연결분산 | pc1-web17, pc2-web17 | 두NodePort진입경로의연결분산 |
| PC1 MAINT | PC1누계17유지, PC2 17→47, 30/30성공 | 수동제외후PC2진입경로처리 |
| MAINT 복귀 | 두서버UP, Backend2/2 | 수동제외복구 |
| 자동장애시험준비 | PC1 30443접속성공, 30446연결거부, Runtime port/check_port30446 | 실패목적지설정확인. 자동DOWN결과는미확인 |
| 시험포트복구 | Runtime port/check_port30443,11443 readiness200 | 실행경로복구. GUI저장값확인도유지필요 |
| 관리GUI포트 | nginx IPv4/IPv6 *:8444, 기존*:443해제 | 서비스443충돌해소 |
| 운영Frontend | HAProxy .3.30:443/11443 리스닝 | 운영listener추가 |
| 운영NAT전환 | telecom-service-https 회색/비활성화 | PC1고정443 NAT해제, 삭제아님 |
| 운영443응답 | HTTP200/database ok, telecom-public-https Sessions Total1 | 공개443이HAProxy를경유함 |

## 포트 변경이 반영되지 않았던 원인과 복구

생성설정은PC1:30446인데실행상태/저장상태파일은30443이었다. `server-state-file /tmp/haproxy_server_state`와`load-server-state-from-file global`을확인했다. 이전포트가상태파일에서복원되는정황으로, 화면의설정만보고목적지변경성공으로판정하지않았다.

Runtime API를통해실행상태를조회했다. 현장backend/server ID는100/101, 소켓은`/tmp/haproxy.socket`이었다. 이름`ipvANY`의v누락,`port`오타,`#101`의#누락으로실패했던명령은성공으로기록하지않는다. 최종적으로시험포트30446과복구포트30443의목적지·검사포트일치를확인했다. 번호는환경마다재조회해야한다.

목적지30446/검사30443의불일치도발생했다. 이때건강검사UP이실제요청성공을뜻하지않으므로두값을함께복구해야한다. 상태파일을삭제하거나생성설정파일을직접편집하지않았다.

## 현재 유지할 설정

- 운영Frontend: `telecom-public-https`, .3.30:443, TCP, Default Backend `telecom-public-nodes`.
- 시험Frontend: `telecom-public-test`, .3.30:11443, TCP. 추가시험완료후제한/비활성화검토.
- 양서버: Active,30443,Basic check2000ms. TCP생존검사이며API/DB전체건강검사가아니다.
- 운영WAN규칙: `telecom-haproxy-public-443`, IPv4/TCP,Source3.0/24,Destination3.30:443,Gateway default/Disable reply-to 적용절차.
- 이전NAT `telecom-service-https`: 비활성화로보관. 구WAN주소8080/8443,PC3전용9443,PC2전용10443은이번변경에서유지.
- pfSense관리: LAN `https://192.168.50.1:8444`. nginx는 전체 주소의8444를 리스닝하므로 관리 접근 제한은 방화벽 규칙으로 유지하고 WAN 전체 허용을 추가하지 않는다.
- Outbound NAT는이번전환에서정리하지않았다. 이후필요성을경로별검토하며일괄삭제하지않는다.

## 남은 검증과 파트 인계

- [ ] 운영443 readiness30회및양backend누계증가,PC1/PC2외CA등록PC접속.
- [ ] 운영443 CUSTOMER/ADMIN로그인·데이터조회,미인증관리API401/CUSTOMER403,공개internal404.
- [ ] 자동DOWN·PC2응답·자동UP증거와실패건수확보. 현재자료로자동전환시간/RTO를기재하지않음.
- [ ] HTTP80→HTTPS443자동이동. [다음설정절차](../runbooks/academy-http-https-redirect.md)는아직미적용.
- [ ] n8n담당자: PC2컨테이너10443접속·CA·Credential·실제이벤트·Discord와일반PC10443차단확인. Windows curl성공과별개.
- [ ] C/B: Suricata의 관측 범위, TLS 암호화 상태에서의 탐지 범위, 실제 클라이언트 IP 전달 여부를 확인한다. TCP 프록시를 추가했으므로 앱에서 보이는 주소를 추정하지 않고 측정한다.
- [ ] B: DB fencing/승격·앱대상전환·PC2방화벽/권한·역할별백업·제어부복구를준비후전체PC장애시험.

PC1 MAINT시험에서도API Service는PC1 Pod를사용할수있고DB는계속PC1에있다. 전체PC1장애승계나무손실복구는입증되지않았다. PC3 pfSense도단일장애점이다.

## 운영443 실패 시 복구

1. 비활성화했던`telecom-service-https` NAT를활성화하고Save/Apply한다.
2. 새운영Frontend `telecom-public-https`를비활성화하고Save/Apply한다. 시험11443과LAN관리8444를구분한다.
3. 새curl연결로기존443 readiness를확인한다. 기존연결은state를유지할수있으며전체state초기화는하지않는다.

관련: [PR #43](https://github.com/telecom-carrier-Loop/telecom-security-project/pull/43), [Issue #44](https://github.com/telecom-carrier-Loop/telecom-security-project/issues/44).
