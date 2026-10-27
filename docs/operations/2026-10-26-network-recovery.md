# 2026-10-26 서비스 IP 적용 및 스위치 재연결 후 네트워크 복구 기록

> 후속: [2026-10-27 복구 결과](2026-10-27-service-recovery.md)에서 두 노드 Ready, HTTPS·DB 응답, Replica 복구 보고, 백업·감시 재개를 기록했다. 아래는 10월 26일 당시 상태이며 재부팅 영구화·DHCP 원인 검증은 계속 남아 있다.

상태: **복구 중**. 기준: 2026-10-26, Asia/Seoul. 사용자가 제공한 현장 실행 화면과 작업 보고를 정리했다. 문서 작성자는 현장 서버에 원격 접속하거나 아래 설정을 직접 적용하지 않았다. [이전 HTTPS 인계](2026-10-26-pfsense-https-access.md) 이후의 결과를 보완한다.

## 1. 마지막으로 확인한 상태

| 대상 | 관측된 결과 | 완료 판단 |
|---|---|---|
| PC1 Windows | `192.168.3.18` 유지 | 물리 PC 주소 변경 없음 |
| PC2 Windows | `192.168.3.19` | 기존 주소 |
| PC1 Ubuntu | `br0`에 `192.168.7.185/24` 수동 복구, SSH TCP 22 성공 | 임시 연결 복구 |
| PC1 k3s | `pc1-k3s`, internal IP `.7.185`, `Ready` | 제공 화면 시점의 노드 상태 |
| PC2 k3s | `pc2-k3s`, internal IP `.7.100`, **`NotReady`** | 복구 미완료; 등록 IP만으로 VM 통신 성공 판단 금지 |
| 공개 HTTPS | `telecom-edge`가 `telecom-public-tls-20261026162357` 참조 | 새 Secret 참조 확인 |
| 공개 HTTPS rollout | `1 of 2 updated replicas are available` 대기 | 전체 배포 완료 아님 |
| 재부팅 후 IP·경로 유지 | 최종 적용·재부팅 결과 미제공 | 미검증 |
| 장애 후 pfSense 경유 웹·DB | 최종 회귀 결과 미제공 | 미검증 |

복구 이후 SSH 연결 성공과 장애 이전의 웹 HTTP 200은 서로 다른 시험이다. 이 문서와 관련 PR 병합은 서비스 복구 완료를 뜻하지 않는다.

## 2. 장애 이전 후속 작업: 새 서비스 IP와 NAT

사용자는 `192.168.3.30`의 사용 승인·중복 방지 확인 완료를 답변했다. 이후 pfSense 화면에서 WAN의 **IP Alias `192.168.3.30/24`** 적용 완료를 확인했다. 이는 사용자 보고와 화면 근거이며 학원 DHCP 서버 설정을 문서 작성자가 조회한 것은 아니다. 이전 문서의 후보 주소 시험은 당시 기록으로 유지한다.

- PC2 Windows에서 `.3.30`의 MAC은 `00-0C-29-98-FE-07 / Reachable`: 실제 pfSense WAN MAC과 일치.
- ICMP ping은 응답이 없었으나, 이를 IP Alias 실패로 판단하지 않았다.
- 새 포트 포워딩: WAN TCP, source `192.168.3.0/24`, destination **`192.168.3.30:443`** → `192.168.7.185:30443`.
- 연결된 WAN 규칙은 NAT 후 목적지 `.7.185:30443`으로 표시. Disable Reply-To 설정 절차를 안내했으나 최종 `pfctl` 출력으로 제거 여부를 별도 재검증하지 않았다.
- Hybrid Outbound NAT의 최상단에 source `.3.0/24`, destination `.7.185/32:30443`, translation **`.3.30/32`** 규칙 추가·적용 화면 확인. 기존 WAN address 변환 규칙보다 먼저 매칭되도록 배치.
- PC1·PC2 Ubuntu에서 `.3.30/32`를 `br0`로 직접 연결하는 임시 반환 경로 확인. 각 source IP는 `.7.185`, `.7.100`이었다.

기존 WAN `.7.178`, 기존 공개 8443, PC3 전용 관리자 9443 규칙은 유지하는 절차로 진행했다. 신규 `.30` 접속 경로는 모든 NodePort 직접 접근 차단이나 고가용성 구현 완료를 의미하지 않는다.

## 3. 장애 이전 시험 범위와 인증서 변경

### 네트워크·API·DB

- PC2 Windows `.3.19` → `.3.30:443`: `TcpTestSucceeded: True`.
- PC3 curl은 `--connect-to "192.168.7.178:8443:192.168.3.30:443"`를 사용해 새 목적지로 연결했고 readiness **HTTP 200**, `database: ok`, `status: ok`, `success: true`를 반환했다.
- 위 curl은 인증서 검증 대상 호스트를 기존 `.7.178`로 유지한 시험이다. 새 IP `.3.30`의 SAN 검증이나 모든 사용자 PC의 브라우저 접속 완료 증거로 사용하지 않는다.

### 인증서

기존 공개 TLS Secret은 `telecom-edge-tls`였고 인증서는 CN `.7.178`, issuer `Telecom Lab Root CA`, SAN `.7.178/.7.185`, 유효기간 2026-10-23 08:00:17 GMT ~ 2027-01-21 08:00:17 GMT였다.

기존 CA로 `.3.30/.7.178/.7.185`를 포함하는 서버 인증서를 별도 발급하고 새 Secret을 생성한 뒤 **공개용 `telecom-edge`만 참조를 교체**하는 절차를 안내했다. 관리자용 Secret은 그대로 두는 설계다. 뒤의 실제 Deployment 조회에서 새 Secret `telecom-public-tls-20261026162357` 참조를 확인했지만 다음은 아직 미확보다.

- 새 인증서의 최종 발급·검증 출력과 실제 제공 인증서 SAN.
- 두 공개 edge Pod의 교체 완료.
- `--connect-to` 없는 `https://192.168.3.30/api/health/ready` 검증.
- PC1·PC2·다른 사용자 PC의 CA 신뢰 및 로그인·데이터 조회.
- 장애 후 기존 PC3 관리자 9443의 회귀 시험.

네트워크 중단 전에 Deployment 변경이 저장됐을 수 있으므로 발급·교체 스크립트를 처음부터 반복하지 않고 현재 Secret 참조와 rollout 상태부터 확인한다. 개인키·Secret data는 이 문서에 포함하지 않는다.

## 4. 스위치 재연결 이후 장애와 진단

사용자는 학원 인터넷 장애로 스위치 연결을 뺐다가 다시 연결한 뒤 VM IP가 잡히지 않았다고 보고했다. **스위치 장애·재연결 이후 발생한 사건**으로 기록하되, 스위치가 설정 파일을 삭제했다거나 장비 고장이 원인이라고 확정하지 않는다. DHCP 서버·스위치 상태 로그는 미확보다.

PC1의 최초 관측:

- `ens33`: UP / LOWER_UP, master `br0`.
- `br0`: UP / LOWER_UP, IPv6 link-local은 있으나 IPv4 없음.
- `ip -4 route`: 당시 출력 없음.
- `/etc/netplan/50-cloud-init.yaml` 존재.
- 병합 설정에서 `br0.dhcp4: true`, `dhcp6: false`, interfaces `[ens33]`.
- `ens33`은 DHCP4/6 false. 실제 IP를 부여할 대상은 `br0`다.

따라서 당초 VM IP는 DHCP로 받던 값이며, `.185`를 수동 추가하는 것만으로 기존 DHCP의 기본 경로·DNS까지 복원되는 것은 아니다. CNI·Flannel·veth 주소는 k3s 네트워크이며 복구 과정에서 삭제하지 않았다.

## 5. 확인된 PC1 임시 복구

| 단계 | 결과 |
|---|---|
| `br0`에 `.7.185/24` 수동 추가 | IPv4 주소 표시 확인 |
| `.3.30/32` 직접 반환 경로 추가 | 경로 출력 확인 |
| 기본 경로 `.7.1` 추가·SSH 시작 | 명령 오류 없음; 이것만으로 연결 성공 판단하지 않음 |
| PC1 Windows → VM | 처음에는 `.3.1` 경유, TCP 22 실패 |
| Windows `.7.185/32` on-link 경로 | ActiveStore, interface 13 `이더넷`, NextHop 0.0.0.0, metric 5 확인 |
| VM → Windows `.3.18/32` | `dev br0 src .7.185` 직접 경로 확인 |
| 초기 ARP | Windows의 `.7.185`가 `00-00-00-00-00-00 / Incomplete` |
| VMware 점검 | VMnet0 → Realtek PCIe GbE Family Controller, VM → Custom VMnet0 확인; 실행 중 Connected 점검 안내 |
| 후속 SSH 시험 | Windows `.3.18` → `.7.185:22` TCP 성공 |
| 후속 ARP | `E2-6A-3D-12-DE-B7 / Reachable`, VM `br0` MAC과 일치 |
| 후속 PuTTY·k3s | 접속 후 PC1 Ready, PC2 NotReady 및 공개 edge rollout 대기 확인 |

Connected가 체크되지 않은 설정 화면은 VM 전원 상태에 따라 비활성화될 수 있다. 점검 안내 뒤 연결이 복구됐다는 순서는 확인되지만 특정 체크박스만이 근본 원인이었다고 단정하지 않는다.

Windows의 `Instance MSFT_NetRoute already exists`는 경로 중복 생성 오류이지 IP 중복 사용 증거가 아니다. 이미 존재하는 경로를 반복 추가하거나 전체 네트워크를 초기화하지 않는다.

## 6. 안내한 후속 복구 절차: 실행 완료와 구분

아래는 다음 작업 순서다. 최종 실행 화면이 없는 항목은 완료로 표시하지 않는다.

1. PC2 VMware에서 실제 유선 어댑터·VMnet0·실행 중 Connected 확인.
2. PC2 `br0` 상태 확인 후 `.7.100/24` 복구; Windows `.3.19`와 VM 사이 직접 경로·SSH 확인.
3. 두 Ubuntu의 Netplan 백업 후 기존 브리지를 유지하는 고정 IP 설정. 기존 파일 위에 별도 설정을 병합하는 절차를 안내했으며 `.3.18/.3.19/.3.30` 직접 경로와 기본 경로·DNS를 포함한다. 실제 적용·재부팅 검증 전까지 영구화 완료로 기록하지 않는다.
4. VMware 콘솔을 확보한 상태에서 `netplan generate` 및 `netplan try`; SSH 확인 후 확정. 실패 시 원본 백업으로 복구하며 자동 롤백만 신뢰하지 않는다.
5. PC2 → PC1 TCP 6443 연결과 `k3s-agent` 상태 확인. 필요한 경우 agent 재시작 후 PC1에서 PC2 Ready 대기. 노드 삭제·재설치 불필요.
6. 두 노드 Ready, Web/API/공개·관리 edge의 필요한 복제본 준비 및 공개 rollout 완료 확인.
7. 각 NodePort 직접 readiness 시험 후 `.3.30:443`의 pfSense 경유 시험. HTTPS 인증서 신뢰·DB 응답·일반 사용자 기능을 각각 검증.
8. PC3 기존 9443 회귀 시험, HTTP 80→HTTPS 443 구성, 추가 사용자 PC 시험, Windows 직접 경로 영구화 및 재부팅 검증.

기본 경로 `.7.1`과 DNS `168.126.63.1/.2`는 앞서 확인한 학원망/pfSense 값에 따른 안내이며 장애 이후 변경됐다면 다시 확인해야 한다. `.7.185/.7.100`은 원래 DHCP 주소였으므로 고정 사용 시 중복 배정 방지도 확인한다. **오늘 남은 작업은 다음 날 이어서 수행할 계획이며 예약 실행을 등록하지 않았다.**

## 7. 완료 기준

- [x] 새 서비스 IP Alias `.3.30/24` 적용 화면 확인.
- [x] 새 443 포워딩·최우선 `.3.30` SNAT 적용 화면 확인.
- [x] 장애 이전 PC2 TCP 443, PC3 connect-to readiness 200 확인.
- [x] PC1 임시 IP·직접 경로 및 SSH 복구 확인.
- [x] 공개 Deployment의 새 TLS Secret 참조 확인.
- [ ] PC2 실제 네트워크·SSH·agent 복구 및 Ready.
- [ ] 공개 HTTPS 2개 복제본 rollout 완료.
- [ ] 장애 이후 `.3.30` 직접 HTTPS·DB·로그인·조회 및 기존 9443 회귀 성공.
- [ ] 두 Ubuntu 고정 IP·경로 및 Windows 경로 영구화·재부팅 검증.
- [ ] HTTP→HTTPS 자동 이동, 추가 사용자 PC CA 신뢰·접속 시험.
- [ ] 스위치/학원망 장애와 DHCP 주소 미수신 원인·재발 방지 확인.

관련 추적: [공통 서비스 주소·HTTPS Issue #33](https://github.com/telecom-carrier-Loop/telecom-security-project/issues/33), [복구 중: 스위치 재연결 후 VM DHCP·PC2 장애 Issue #36](https://github.com/telecom-carrier-Loop/telecom-security-project/issues/36). 문서 PR 병합만으로 두 이슈를 종료하지 않는다.
