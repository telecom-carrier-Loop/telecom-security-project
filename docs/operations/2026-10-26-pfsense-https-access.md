# 2026-10-26 pfSense HTTPS 접속 구성과 학원망 접속 장애 인계

기준일: **2026-10-26, Asia/Seoul**. 인프라(B)·네트워크(C) 작업을 함께 수행하는 담당자를 위한 현장 기록이다. 근거는 사용자가 제공한 실행 화면, `telecom-edge` Deployment·Service 출력, pfSense 규칙·패킷 캡처다. 문서 작성 과정에서 현장 서버에 원격 접속하거나 설정을 변경하지 않았다.

**최신 상태는 [서비스 IP 적용 및 네트워크 복구 기록](2026-10-26-network-recovery.md)을 따른다.** 아래는 PR #34 작성 시점의 기록이다. 이후 `.3.30` IP Alias·443 NAT/SNAT와 일부 연결 시험을 진행했고, 스위치 재연결 이후 VM DHCP 주소 미수신으로 현재 **복구 중**이다. 후보·미적용으로 적힌 아래 5절은 당시 계획이며 최신 완료 상태로 해석하지 않는다.

## 1. 확인된 주소와 역할

| 대상 | 주소 / 역할 |
|---|---|
| PC1 Windows | `192.168.3.18`, Docker MySQL Primary |
| PC2 Windows | `192.168.3.19`, Docker MySQL Replica; 시험 인터페이스 번호 `17` |
| PC3 Windows | `192.168.3.20/24`, 물리 NIC MAC `3C-7C-3F-2C-6C-FC` |
| PC1 Ubuntu | `192.168.7.185`, `pc1-k3s`, control plane + worker |
| PC2 Ubuntu | `192.168.7.100`, `pc2-k3s`, worker |
| pfSense WAN | `em0`, `192.168.7.178/24`, DHCP, gateway `192.168.7.1`, MAC `00:0c:29:98:fe:07` |
| pfSense LAN / PC3 VMnet4 | `192.168.50.1/24` / `192.168.50.100/24` |

PC1 Ubuntu에서의 성공을 PC1 Windows에서의 성공으로 기록하지 않는다. 같은 학원망이라는 설명만으로 모든 PC의 L2 연결·대역 간 라우팅을 보장하지 않는다. 기존 DMZ/WAS/DB/SEC 인터페이스는 down 상태이며, 이를 이번 장애의 원인으로 확정하지 않았다.

## 2. 공개 HTTPS와 관리자 경로 분리

### 공개 진입점

- `https://192.168.7.178:8443` → pfSense → `192.168.7.185:30443` → `telecom-edge`.
- `telecom-edge` Service는 `443 → https(컨테이너 8443)`, NodePort `30443`, `externalTrafficPolicy: Cluster`.
- 첨부 Deployment 시점에서 replicas / ready / available 모두 2. 이미지: `docker.io/library/telecom-frontend:k3s-f7a8c86eb92c-20261023120455`.
- ConfigMap `telecom-edge-config`의 `nginx.conf`를 subPath로 마운트하고 TLS Secret `telecom-edge-tls` 사용. 이 이미지가 최신 main과 일치한다는 뜻은 아니다.
- `/api/`는 `telecom-api:5000`, `/`는 `telecom-web:80`으로 전달.
- `/admin`, `/admin/*`, `/api/admin`, `/api/admin/*` 및 `/api/internal` 계열은 Nginx에서 404로 차단.

PC3의 `/api/admin/dashboard` 요청은 Nginx HTML 404였다. 앞서 확보한 실제 차단 설정과 일치하며, 이 요청은 DB 조회 전에 거절되는 경로다. 일반 웹 조회 실패를 모두 DB 장애로 취급하지 않는다.

### 관리자 진입점

별도 관리용 리소스 `telecom-admin-edge`, `telecom-admin-edge-config`, NodePort `30444`를 추가하는 절차를 안내했고, 후속 화면·사용자 보고로 `9443`의 API 및 관리자 화면 접속 성공을 확인했다.

안내한 설계는 다음과 같다. 관리용 리소스의 최종 전체 YAML·두 Pod 배치 및 모든 제한 시험 결과는 별도 보관·재확인이 필요하다.

- 공개 설정을 복제하되 관리자 차단 4개만 제거; 내부 API 차단과 Flask 인증·RBAC 유지.
- 관리용 Nginx는 pfSense WAN `192.168.7.178`만 허용.
- 관리용 Service는 `externalTrafficPolicy: Local`; 노드별 관리용 Pod 배치 필요.
- pfSense는 PC3 `192.168.3.20/32`만 `9443 → 192.168.7.185:30444`로 허용.
- 관리용 SNAT는 PC3 → PC1:30444의 출발지를 WAN address로 변환.

검증 증거:

| 시험 | 관측 / 한계 |
|---|---|
| PC3 `9443/api/health/ready` | HTTP 200, `database: ok`, `status: ok`, `success: true` |
| PC3 쿠키 없는 `9443/api/admin/dashboard` | JSON HTTP 401 `UNAUTHORIZED`; 로그인 정보 없는 요청의 인증 거절 |
| PC3 브라우저 `9443` | 사용자가 관리자 화면 접속 성공 보고 |
| 이후 접속 | 일시 중단 후 다시 접속됐다고 보고; 안정화 완료 아님 |
| 직접 NodePort 우회 차단·내부 API 차단·비관리자 권한 검사 | 안내했으나 전체 시험 결과 미확보 |

관리자 자동 포트 이동은 검토 요청만 있었고 코드 변경·배포는 하지 않았다. 구현하더라도 브라우저 리디렉션이며 NAT가 사용자 역할을 판별하는 기능이 아니다. PC3 IP 제한을 우회할 수 없고, 같은 호스트의 쿠키는 포트만으로 분리되지 않는다.

## 3. 최종 화면에 나타난 pfSense NAT 규칙

| WAN 목적지 포트 | Source | 전달 대상 |
|---|---|---|
| 8080 | any | `192.168.7.185:30080` |
| 8443 | any | `192.168.7.185:30443` |
| 9443 | `192.168.3.20` | `192.168.7.185:30444` |

Outbound NAT는 Hybrid 모드다. 아래 조건을 WAN address로 변환하는 수동 규칙이 화면에 존재한다.

- `192.168.7.0/24` → `192.168.7.185/32`, TCP 30080 / 30443 각각.
- `192.168.3.0/24` → `192.168.7.185/32`, TCP 30080 / 30443 각각.
- `192.168.3.20/32` → `192.168.7.185/32`, TCP 30444.

규칙 존재는 실제 통신 성공과 다르다. Source any는 경로를 생성하지 않으며, 다른 학원 사용자 모두에게 접속이 검증됐다는 뜻도 아니다.

## 4. PC1·PC2 접속 장애에서 확보한 증거

1. PC1 Ubuntu에서 `.185:30443` 및 `.100:30443` readiness 요청은 각각 3회 HTTP 200이었다. 이 시험만으로 각 노드의 특정 Pod가 응답했다고 단정하지 않는다.
2. PC1 Ubuntu에서 `.178:8443`은 처음 TCP 연결 시간 초과. 이웃 정보를 삭제·재확인한 뒤 실제 pfSense MAC으로 바뀌었고, readiness 요청 3회 HTTP 200 및 DB ok를 확인했다. 근본 원인 해결을 의미하지 않는다.
3. PC2 Windows는 `.3.19`에서 기본 게이트웨이 `.3.1`을 경유했고 TCP 8443 시험 실패. `.178` 이웃 정보가 없었던 것은 당시 경로와 일치한다.
4. PC2에 `.178/32`, interface 17, NextHop `0.0.0.0`, metric 5의 **ActiveStore 임시 경로**를 추가했다. 이후 TCP 시험은 한 번 성공했지만 실제 HTTPS curl은 계속 연결 시간 초과였다.
5. PC2의 `.178` 이웃 MAC은 반복해서 `F4-B5-20-63-3C-70`으로 관측됐다. 삭제 후에도 다시 나타났으며 실제 pfSense WAN MAC과 다르다. PC3의 표시된 Windows 어댑터 MAC과도 일치하지 않았다. PC3 Windows IP 목록에 `.178`은 없었다.
6. pfSense `em0` 캡처에는 PC2 `.3.19`의 ARP 요청, 실제 WAN MAC의 ARP 응답, PC2 → `.178:8443` SYN이 보인다. 해당 SYN의 목적지 MAC은 실제 pfSense MAC이었다.
7. 제공된 캡처는 이전 필터 `arp … or (host .3.19 and tcp port 8443)`로 수행되어, NAT 이후 `30443` 통신을 관측하기에 부족하다. SYN-ACK 부재나 백엔드 전달 실패를 이 캡처만으로 확정하지 않는다.
8. 제공된 `pfctl -sr -vv`의 일반 웹 30443 규칙에는 `reply-to (em0 192.168.7.1)`이 남아 있었다. `route -n get 192.168.3.19`도 기본 경로 `.7.1`을 선택했다. 이후 GUI에서 Disable Reply-To를 적용하라는 안내가 있었으나 제거된 최종 규칙 출력은 미확보다.

**미확정 원인:** 다른 장비의 IP 중복 사용, Proxy ARP, 학원망 정책·가상화 네트워크 처리, 요청·응답 경로 불일치. 특정 장비나 ARP 공격으로 단정하지 않는다. `F4-B5-20-63-3C-70`의 소유 장비도 미확인이다.

Windows curl의 별도 Schannel 폐기 확인 오류는 `--ssl-revoke-best-effort`로 시험했을 때 해소된 적이 있다. 이는 TCP 시간 초과와 다른 문제이며 브라우저 정책이나 전체 인증서 검증을 비활성화한 조치가 아니다.

## 5. 새 서비스 주소와 HTTP→HTTPS 구성: 미적용 계획

요구사항은 일반 사용자가 별도 SSH 터널·수동 경로 없이 서비스 주소로 접속하고, HTTP는 HTTPS로 이동하며 pfSense를 경유하는 것이다. 현재 `8443` 포워딩만으로는 포트 생략 접속이나 HTTP→HTTPS 전환이 구현되지 않는다.

### 후보 주소 검사

`192.168.3.30`은 **후보일 뿐 할당받지 않았다**. PC3 시험에서 시간 초과와 `.3.20`이 보낸 대상 호스트 도달 불가가 나왔고, 이웃 정보는 `00-00-00-00-00-00 / Unreachable`이었다. ping 통계의 수신 1은 `.30`의 정상 Echo Reply 성공으로 보지 않는다. 무응답·Unreachable은 미사용 증명이 아니며 DHCP 범위 제외·기존 고정 할당 확인이 필요하다.

### 적용 전 검토 순서

1. 학원망 관리자가 승인한 `192.168.3.0/24` 서비스 IP 확보. `.18/.19/.20` 재사용 금지; `.30` 임의 배정 금지.
2. pfSense 백업 후 WAN의 추가 **IP Alias**로 구성하는 안 검토. 현재 L2 도달성과 학교망의 추가 IP 허용 정책을 확인하고 새 IP의 ARP 응답을 검증한다.
3. 새 주소를 사용하는 Outbound NAT와 Ubuntu 두 노드의 해당 주소 `/32` 반환 경로를 함께 설계·시험한다. 새 IP 추가만으로 양방향 연결이 해결된다고 가정하지 않는다.
4. 새 서비스 IP를 SAN에 포함하는 서버 인증서 발급. 기존 주소 SAN·CA 신뢰 및 공유 TLS Secret의 공개/관리용 영향 확인. 공개 CA 인증서만 배포하고 개인키는 공유하지 않는다.
5. k3s HTTP 리디렉션 리스너·Service 추가. NodePort 30081은 사용 여부 확인 전에는 확정값이 아니다. 기존 30080은 자동 리디렉션 서비스가 아니다.
6. 새 서비스 IP의 80 → 리디렉션 포트, 443 → 30443 NAT 및 해당 소스 범위 허용 규칙 구성. 새 VIP를 목적지로 명시하고 관리 GUI 노출 여부 확인.
7. PC2·PC1·별도 사용자 PC에서 HTTPS 신뢰, readiness, 로그인·조회, 반복 접속, 관리자/내부 API 제한, 기존 PC3 9443 회귀 시험.
8. 성공 후에만 영구 경로·주소 관리 방식 확정 및 기존 임시 경로 정리. 다른 서브넷·VLAN 사용자는 별도 학원망 라우팅 승인이 필요할 수 있다.

이 계획은 미실행이다. 실제 주소·인터페이스·인증서 발급 경로를 확인하기 전 실행용 배포 스크립트로 취급하지 않는다. 서비스의 pfSense 경유 접속을 구성하는 것과 NodePort 등 모든 우회 경로를 차단하는 것은 별도 검증 항목이다.

## 6. 이어서 수행할 검증과 복구 범위

- [ ] PC3 8443/9443 접속을 반복 시험하고 시간·HTTP 상태·MAC을 함께 기록.
- [ ] `.178`의 다른 MAC 소유·응답 원인을 PC2 측 ARP 캡처와 네트워크 관리자 확인으로 식별.
- [ ] 일반 웹 규칙의 실제 reply-to 유무, PC2 반환 경로, 기존 state 영향을 구분.
- [ ] WAN 캡처에 TCP 8443과 30443을 모두 포함해 요청·응답 확인. 캡처에 보이는 목적지 MAC도 함께 해석.
- [ ] 새 서비스 IP 승인과 DHCP 중복 방지 확인. 승인 전 `.30` 추가 금지.
- [ ] 관리용 리소스 최종 설정과 사용자 제한·우회 차단을 저장소에 별도로 반영.
- [ ] 관리자 자동 리디렉션은 IP 제한·서버 RBAC·쿠키/CSRF 동작을 검토한 뒤 별도 작업.

PC2의 `.178/32` 경로는 ActiveStore 시험용으로 추가됐고 제거·영구 저장 완료 증거는 없다. 삭제 시 해당 주소·interface 17·NextHop 0.0.0.0의 항목만 지정하고 다른 PC에 인터페이스 번호를 복사하지 않는다. 전체 ARP/state 초기화, MAC 강제 고정, 방화벽 전체 해제는 해결 절차로 삼지 않는다.

관리용 변경을 되돌릴 때는 새 9443 NAT·연결된 허용 규칙·30444 SNAT 및 관리용 Deployment/Service/ConfigMap만 대상으로 한다. 공개 edge·공유 TLS Secret·DB를 함께 삭제하지 않는다. 이번 문서 PR은 현장 리소스·인증서·DB·프런트엔드를 수정하지 않는다.

## 7. 근거와 관련 문서

- [후속 장애·서비스 주소 구성 추적: Issue #33](https://github.com/telecom-carrier-Loop/telecom-security-project/issues/33): 문서 PR 병합과 별개로 실제 완료 기준을 검증한다.
- [기존 인프라 정리](2026-10-25-infra-status.md): 이전 k3s·DB 백업·복원·Discord 작업 범위.
- [pfSense IP Alias](https://docs.netgate.com/pfsense/en/latest/firewall/virtual-ip-addresses.html)
- [pfSense 포트 포워딩](https://docs.netgate.com/pfsense/en/latest/nat/port-forwards.html)
- [pfSense Disable Reply-To](https://docs.netgate.com/pfsense/en/latest/firewall/configure.html#disable-reply-to)
- [Kubernetes Service 출발지 IP](https://kubernetes.io/docs/tutorials/services/source-ip/)
- [쿠키는 포트로 격리되지 않음: RFC 6265 §8.5](https://www.rfc-editor.org/rfc/rfc6265#section-8.5)

스크린샷과 첨부 YAML의 관측값만 필요한 범위로 전사했다. 원본 pfSense XML·Secret 데이터·개인키·세션 쿠키·웹훅은 포함하지 않는다. 문서 PR 병합은 장애 해결이나 새 서비스 주소 적용 완료를 의미하지 않는다.
