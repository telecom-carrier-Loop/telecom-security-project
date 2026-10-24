# 인프라 담당 작업 정리와 다음 현장 점검

정리일: **2026-10-25, Asia/Seoul**. 작업 근거는 2026-10-22~23 사용자 실행 화면, 기존 저장소 기록, 사용자가 제공한 「PC1 SSH 접속·터널링 대화 정리」다. 10월 25일에 현장 서버를 새로 조회하거나 배포한 기록은 아니다. pfSense 설정·정책과 관제 담당자의 작업은 이번 정리 범위에서 제외한다.

## 1. 기존 문서와 이번 보완 범위

| 구분 | 기록 위치·보완 내용 |
|---|---|
| k3s 구축·웹 최초 배포 | [10월 22일 인계](2026-10-22-k3s-web-handoff.md)에 이미 기록됨. 해당 날짜의 이미지·진입점은 당시 값 |
| 복제·예약 백업 영향 | [k3s 이전 영향 점검](../runbooks/mysql84-k3s-impact.md), [예약 백업](../runbooks/mysql84-backup-schedule.md)에 이미 기록됨 |
| 이후 격리 복원 결과 | 아래에 실제 후속 화면 결과와 적용 범위를 보완 |
| 백업 Discord 알림 | [도구·실행 절차](../runbooks/mysql84-restore-discord.md)는 있음. 구현·시험 전송·자동 등록 증거를 구분해 보완 |
| k3s HTTPS edge | 후속 작업 요약에 있는 배포·직접 연결 결과를 저장소 현장 기록으로 추가 |
| 재배포·일상 재개 | 신규 변경 반영과 단순 재부팅을 구분하고 다음 현장 확인 순서를 정리 |

## 2. k3s·DB 구성과 배포 확인 범위

| 대상 | 확인된 역할·값 |
|---|---|
| PC1 Ubuntu | `pc1-k3s`, `192.168.7.185`, k3s Server + Worker |
| PC2 Ubuntu | `pc2-k3s`, `192.168.7.100`, k3s Agent/Worker |
| 앱 | namespace `telecom`, Web·API 각 2개 복제본으로 구성 |
| PC1 Windows DB | `flask_mysql`, `192.168.3.18:3306`, `my_new_board_db`, Primary |
| PC2 Windows DB | `mysql-lab`, Replica, 기존 주소 `192.168.3.19`는 재개 시 재확인 |
| 최초 웹 검증 | React/Nginx → Flask → MySQL 조회, 로그인 후 회원 목록 및 관측된 업무 API HTTP 200 |

웹 이전 시 두 노드의 테스트 Pod에서 PC1 DB의 TCP 3306 연결을 확인했고, 실제 앱 조회로 DB 연결도 별도 확인했다. TCP 연결만으로 DB 인증·업무 기능을 검증한 것으로 보지 않는다.

후속 이미지 전송 화면에서는 실행 중 API 이미지 태그와 현재 Git 커밋이 다른 상태가 발견됐다. 새 이미지 세 개의 빌드·전송 진행 보고가 있었지만, 최종 Web·API·Migration 이미지와 DB revision이 모두 최신 커밋에 일치한다는 완료 증거는 아직 없다. 최초 `k3s-v1`을 현재 최신 버전으로 간주하거나, 전송 완료를 배포 완료로 기록하지 않는다.

## 3. 격리 복원 후속 확인

웹 이전 후 예약 백업의 실제 Task Scheduler 실행은 2026-10-22 22:25 KST에 성공했다. 이후 제공된 RestoreTest 화면에서 다음을 확인했다.

- `PASS: isolated restore verified; 22 tables CHECK TABLE OK; row counts saved.`
- 백업 상태 `Stage=restore-verified`.
- 격리 시험 컨테이너 `exited`, 종료 코드 `0`.
- 원래 `mysql-lab` 컨테이너는 `running` 유지.
- 시험 전체 경과 시간은 사용자 측 측정으로 약 **16.8초**.

이는 당시 백업의 격리 복원·테이블 검사 결과다. 16.8초는 서비스 전체 복구 시간(RTO)이 아니며 PC 장애 전환·앱 복구·복제 원복의 검증도 아니다. 후속 화면은 과거 인계의 미검증 항목을 보완하며, 과거 날짜 문서 자체의 기록은 유지한다.

그 뒤 공지사항·상점 등의 테이블·컬럼을 추가하는 웹 변경이 있었으므로, 다음 검증에서는 **변경이 반영된 새 백업**을 사용한다. 테이블 수를 22개나 25개로 고정하지 말고 실제 Migration·테이블 목록과 복원 결과를 비교한다. 라이브 DB에 기존 전체 초기화 SQL을 적용하거나 과거 덤프로 덮어쓰지 않는다.

## 4. DB 백업 Discord 감시의 구현과 현장 증거

이 경로는 DB 백업 실행 기록을 검사하는 도구이며, 보안 관제용 Wazuh → Graylog → n8n 알림과 별개다.

| 항목 | 확인 범위 |
|---|---|
| 도구·판정 시험 | 실패·지연·파일 누락·상태 손상·중복 억제·정상화·전송 재시도 등의 코드와 대역 시험이 저장소에 있음 |
| 웹훅 저장·시험 전송 | 사용자가 실행했다고 명시적으로 확인 |
| 한국어 문구 | KST 시각과 실제 경과 시간을 표시하도록 코드·시험·문서 반영 |
| 자동 감시 등록 | 등록 진행 요청은 있었지만 최종 Install 성공·예약 상태·주기 실행 결과는 제공 기록에서 확인되지 않음 |
| 실제 백업 장애 알림 | 시험 전송 성공과 구분. 현장 장애 조건에서 자동 알림이 도착한 결과는 아직 확인되지 않음 |

구현된 기준은 5분 주기 점검, 마지막 백업 성공 후 90분 초과, 실행 중 작업의 12분 초과 미완료 등이다. **12분은 새 백업이 없었던 시간이 아니라 시작된 백업이 끝나지 않은 시간**이다. 메시지는 점검 당시 실제 경과 시간을 표시한다. 정상화 1회, 같은 이상 60분 후 재알림 등 상세 조건은 [감시 절차](../runbooks/mysql84-restore-discord.md)를 따른다.

도구는 복제 상태를 매 5분 SQL로 조회하는 상시 감시기가 아니다. 복제 검사는 백업 preflight와 별도 직접 점검으로 확인한다. PC2 전원 OFF·절전·로그아웃 시 백업과 감시가 함께 멈추며, 이 도구만으로 PC2 전체 장애를 외부에 알릴 수 없다.

## 5. k3s 측 HTTPS edge 후속 작업

사용자가 제공한 SSH·HTTPS 요약의 실행 결과 기준이다. 서버 측 구성만 기록하며 외부 경계 장비 설정은 다루지 않는다.

| 항목 | 확인된 상태 |
|---|---|
| TLS Secret | `telecom-edge-tls`, 유형 `kubernetes.io/tls`, 데이터 항목 2개 |
| HTTPS edge | PC1·PC2에 각각 하나씩 `1/1 Running` |
| Service | `telecom-edge`, `443:30443/TCP` |
| 앱 프록시 설정 | `TRUSTED_PROXY_HOPS=1` 적용 |
| 직접 시험 | 공개 CA 인증서 검증을 통과하고 `/api/health/ready`의 DB `ok` 응답 확인 |

이 시험은 `curl --connect-to`로 인증서 검증 대상 주소를 유지하면서 실제 TCP 연결은 **PC1 `192.168.7.185:30443`으로 직접** 보냈다. 외부 경계 경유 성공·브라우저 로그인·PC2 직접 연결·전체 장애 전환 성공의 증거는 아니다. 프록시 홉 설정만으로 원본 클라이언트 IP나 헤더 신뢰 관계가 검증됐다고 보지 않는다.

기존 `localhost:18080` 경로는 Windows SSH 터널과 Ubuntu `kubectl port-forward` 두 프로세스가 필요한 임시 확인 경로다. HTTPS NodePort 직접 시험에는 그 터널을 쓰지 않는다. 공개키 SSH 인증 성공·호스트 지문 비교·SSH 접근 제한은 이번 요약만으로 확인할 수 없으므로 완료로 기록하지 않는다. 공개 CA 인증서와 SSH/TLS 개인키를 구분하고, 비밀키·Secret 본문은 저장소나 PR에 첨부하지 않는다.

현재 HTTPS edge의 Deployment·설정·인증서 생성 절차에 대한 비밀 없는 현장 사본은 저장소에서 확인되지 않았다. 다음 현장에서 동작 중 구성과 대조한 사본을 확보한 뒤 재현 가능한 배포 절차를 보완한다. 예제 YAML을 추측하여 현장 구성에 덮어쓰지 않는다.

## 6. 변경 반영과 단순 재시작의 구분

| 상황 | 필요한 작업 |
|---|---|
| 코드 변경 없는 다음 날 재개 | 기존 컨테이너·VM·k3s 시작 후 노드·DB·백업·앱 점검. 이미지 빌드·Migration·k3s 재설치는 불필요 |
| 웹·API 코드 변경 | 기준 Git 커밋 확인 → 해당 이미지 새 태그 빌드 → 실행할 두 노드에 반입 → 현장 Deployment 변경 → rollout·업무 검증 |
| DB 스키마 변경 포함 | 변경 전 백업·복제 확인 → Migration 내용·기존 revision 확인 → 릴리스 호환 순서에 맞춰 1회 적용 → Web·API 배포 → 복제·데이터 검증 → 새 백업·격리 복원 |
| 공개키 SSH 등록만 수행 | 관리 접속 인증 변경. 앱 이미지 재빌드 사유가 아님 |
| TLS·ConfigMap·Secret 변경 | 실제 소비 방식에 맞춰 반영·재시작·인증서 검증. 환경변수·subPath 마운트는 기존 Pod에 자동 반영된다고 가정하지 않음 |

`git pull`은 실행 중인 컨테이너·Kubernetes 이미지·DB Migration을 갱신하지 않는다. 양쪽 VM에 이미지를 반입해도 Deployment가 이전 태그를 사용하면 이전 앱이 계속 실행된다. 로컬 수정이 있으면 먼저 차이를 보존·검토하고 `reset --hard`나 전체 `git clean`으로 지우지 않는다.

현장 적용 파일과 실행 컨테이너 이름·이미지·Migration revision을 확인한 뒤 구체적인 배포 명령을 정한다. Migration 기록을 최신으로 표시하는 것만으로 실제 스키마가 생성되지는 않으므로, 수동 SQL과 Migration을 같은 변경에 중복 실행하거나 `stamp`만으로 적용을 대체하지 않는다. 실패 시에는 DB 변경의 되돌리기 가능성과 앱 호환성을 확인하고 원인을 해결한다.

## 7. 다음 현장 읽기 점검과 남은 작업

2026-10-26 현장에서 최신 상태를 다시 확인한다. 다음은 **PC1 Ubuntu**의 조회 명령이며 서버 시작·배포·DB 변경 명령이 아니다.

```bash
hostname
sudo k3s kubectl get nodes -o wide
sudo k3s kubectl -n telecom get deployment,pods,service -o wide
sudo k3s kubectl -n telecom get deployment -o 'custom-columns=NAME:.metadata.name,READY:.status.readyReplicas,IMAGES:.spec.template.spec.containers[*].image'
sudo k3s kubectl -n telecom get secret telecom-edge-tls
```

Secret 조회에 `-o yaml`/`-o json`을 붙여 내용을 공개하지 않는다. SSH 호스트 지문과 인증서 유효기간·SAN은 개인키 내용을 출력하지 않는 방식으로 현장에서 별도 확인한다.

**PC2 Windows의 원래 백업 사용자**로 기존 [예약 상태 점검](../runbooks/mysql84-k3s-impact.md#지금-가능한-읽기-점검)을 수행한다. Discord 감시는 다음 명령으로 등록 여부·최근 실행 시각·종료 코드만 확인할 수 있다.

```powershell
$loopMonitorName = 'Loop-MySQL84-PC2-Backup-Discord-Monitor'
Get-ScheduledTask -TaskName $loopMonitorName -ErrorAction Stop |
    Select-Object TaskName,State
Get-ScheduledTaskInfo -TaskName $loopMonitorName -ErrorAction Stop |
    Select-Object LastRunTime,LastTaskResult,NextRunTime
```

작업이 없으면 설치 완료로 기록하지 않고 [등록 절차](../runbooks/mysql84-restore-discord.md)를 따른다. `Ready`나 종료 코드 0만으로 실제 Discord 수신까지 성공했다고 판단하지 않는다. 운영 DB 중지나 상태 파일 변조로 실패 시험을 만들지 않는다.

후속 우선순위:

1. 실제 소스·실행 이미지·DB revision과 HTTPS 설정의 대응 관계 확인.
2. HTTPS 브라우저 로그인·조회·신규 웹 기능 및 두 노드의 직접 연결 시험.
3. Discord 감시 등록·주기 실행·전송 기록 확인과 최신 스키마의 백업·격리 복원.
4. 앱 전용 최소 권한 DB 계정, k3s 단일 제어부 복구, 외부 백업 사본 준비.
5. DB 수동 승격·원복과 역할별 백업 설계. PC2 승격 후 기존 Replica 보호 검사를 단순 제거하지 않음.

일상 종료·시작 순서는 [운영 절차](../runbooks/k3s-mysql-daily-operations.md)를 따른다. 해당 절차는 PC1 Primary / PC2 Replica 역할 유지와 Discord 감시 등록 완료를 전제하므로, 등록되지 않은 경우 그 전제를 먼저 해소한다. DB 관리자 암호 입력 착오에 대한 사용자 정정은 있었지만, 이를 모든 접속 경로의 인증 성공이나 비밀번호 초기화 완료로 기록하지 않는다.

## 8. 검증 한계

이번 변경은 현장 결과를 정리한 문서다. 현장 배포 파일·실행 환경은 직접 조회하지 않았고 라이브 DB, 예약 작업, SSH, HTTPS, Discord를 새로 실행하지 않았다. 백업 파일 생성·격리 복원·브라우저 기능·자동 장애 전환은 서로 다른 검증 항목으로 유지한다.
