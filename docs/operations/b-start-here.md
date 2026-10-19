# B 담당 개발·실습 시작 가이드

## 현재 완료 범위

B는 Docker·Compose·k3s·호스트 Nginx·웹 Keepalived·MySQL 복제·백업·복원을 담당합니다. A의 앱 코드, C의 방화벽·NetworkPolicy, D의 관제 구성은 해당 담당자가 작성합니다.

| 항목 | 준비 상태 | 다음 조건 |
|---|---|---|
| Docker Desktop | 오류 복구 후 Engine 응답 확인 | 아래 실습부터 시작 |
| 로컬 TLS·Compose·앱 Dockerfile | 작성, 프록시는 임시 테스트 서버로 검증 | A 앱 코드가 들어오면 실제 이미지 빌드 |
| MySQL GTID 복제·읽기 전용 Replica | 격리된 새 Docker 프로젝트에서 검증 | 공용 PC 전용 실행 구성·계정·TLS는 장비 확인 후 작성 |
| 별도 DB 복원 | 합성 데이터로 검증 | 운영용 GPG 암호화·외부 매체 복구 시험 별도 |
| k3s·Nginx·Keepalived | 템플릿 작성 | Ubuntu·NIC·VLAN·인증서·C 정책 확인 후 적용 |

이 단계는 인프라 기반입니다. 앱 전체 실행, 공용 PC 설치, HA 완성 또는 운영 배포 완료를 뜻하지 않습니다.

## 오늘 직접 할 일 3가지

1. 아래 MySQL 실습 명령을 실행하고 `PASS`를 확인합니다. 이미 이 PC에서 자동 검증한 결과는 [검증 기록](b-verification.md)에 있습니다.
2. PC1·PC2의 OS·CPU·RAM·디스크·유선 LAN 포트 수를 확인합니다. Windows면 작업 관리자 → 성능과 설정 → 시스템 → 정보를 확인합니다. Ubuntu면 아래 인벤토리 명령을 실행합니다.
3. LAN 케이블이 꽂히는 스위치의 제조사·모델명을 확인합니다. 장비가 없다면 미보유로 기록합니다. 구매는 모델과 구성 확인 후 결정합니다.

스위치는 여러 PC의 유선 LAN을 연결하는 장비입니다. 계획한 VLAN을 물리적으로 나누려면 802.1Q VLAN·트렁크를 지원하는 관리형 스위치가 필요합니다. Suricata로 트래픽을 복제하려면 SPAN/포트 미러링 지원 여부도 확인해야 합니다. 공유기의 LAN 포트가 같은 기능을 제공한다고 가정하지 않습니다. VM 내부 실습은 가상 스위치로 먼저 할 수 있지만 물리 VLAN 검증을 대신하지 않습니다.

pfSense VM은 실행 중인 PC에 의존합니다. 해당 PC 전원·하이퍼바이저가 내려가면 라우팅/VPN도 함께 중단될 수 있습니다. 웹 VIP만으로 이 장애가 해결되지 않으며 C와 VM 위치·자동 시작·NIC 연결을 먼저 결정합니다.

## 1. 저장소 위치와 브랜치

현재 PC의 PowerShell:

```powershell
Set-Location 'C:\Users\rudrn\OneDrive\Documents\ChatGPT\SKT 알래프\telecom-security-project'
git status
git branch --show-current
```

B 기반 작업 브랜치는 `codex/b-infrastructure-foundation`입니다. PR을 검토해 `develop`에 통합한 뒤 후속 작업은 최신 `develop`에서 새 `codex/b-작업명` 브랜치로 시작합니다. 다른 사람의 미커밋 변경이 있으면 브랜치를 바꾸기 전에 보존합니다.

## 2. Docker 확인과 복제 실습

```powershell
docker version
docker compose version
python --version
python infrastructure/tools/mysql-lab.py prepare
python infrastructure/tools/mysql-lab.py init
python infrastructure/tools/mysql-lab.py verify
python infrastructure/tools/mysql-lab.py status
python infrastructure/tools/mysql-lab.py restore-test
python infrastructure/tools/mysql-lab.py down
```

- `init`: 전용 컨테이너 2개와 볼륨을 만들고 GTID 복제를 연결합니다. 호스트 DB 포트는 열지 않습니다.
- `verify`: Primary에 합성 행을 쓰고 Replica 적용·읽기 전용·앱 계정의 쓰기 거절을 확인합니다. 결과는 `B-DB-REPLICATION PASS`입니다.
- `restore-test`: 별도 복원 컨테이너의 빈 `telecom_restore_test`에 복원하고 합성 행 수를 비교합니다. 결과는 `B-DB-RESTORE PASS`입니다.
- `status`: 서버 ID·GTID·읽기 전용 플래그·복제 상태와 오류 번호만 출력합니다.
- `down`: 컨테이너를 중지·제거하고 볼륨과 백업은 보존합니다. `down -v`, volume prune, factory reset을 실행하지 않습니다.

복원 대상에 이미 테이블이 있으면 재실행은 거절됩니다. 반복 검증은 모든 명령에 동일한 새 프로젝트명을 붙입니다. 예: `python infrastructure/tools/mysql-lab.py init --project telecom-b-db-lab-practice2`. 이어지는 `verify`, `restore-test`, `down`에도 같은 옵션을 사용합니다. 프로젝트마다 볼륨이 남으므로 계속 새로 만들지 않습니다.

실습용 복제 TLS는 암호화되지만 서버 신원 검증은 하지 않습니다. 공용 PC는 별도 CA·서버 인증서와 `VERIFY_IDENTITY`/복제 서버 인증서 검증을 적용해야 합니다. 로컬의 `%` 계정·root 사용을 운영 구성으로 복사하지 않습니다.

## 3. A 코드가 들어오기 전·후

지금은 다음 4개 파일이 없어서 앱 빌드를 진행하지 않습니다.

```text
frontend/package.json
frontend/package-lock.json
backend/requirements.txt
backend/wsgi.py
```

A가 추가한 후 다음을 확인합니다.

```powershell
python infrastructure/tools/preflight.py --app
python infrastructure/tools/prepare-local.py
docker compose --env-file .env -f infrastructure/docker/compose/local/compose.yaml --profile app --profile ops config --quiet
docker compose --env-file .env -f infrastructure/docker/compose/local/compose.yaml up -d mysql
docker compose --env-file .env -f infrastructure/docker/compose/local/compose.yaml --profile ops run --rm --build migrate
docker compose --env-file .env -f infrastructure/docker/compose/local/compose.yaml --profile app up --build -d
```

Migration은 A의 Flask-Migrate 설정과 `database/migrations/`가 준비된 뒤 한 번만 실행합니다. 실패하면 앱 실행을 멈추고 원인을 수정합니다. 로컬 ops는 격리된 MySQL의 root 계정을 사용하고 앱 런타임과 비밀번호를 분리합니다. 공용 PC는 별도 DDL 계정과 최소 권한 앱 계정이 필요합니다.

`prepare-local.py`는 Git에서 제외되는 `.env`와 `.secrets/tls/`를 만들며 기존 파일을 덮어쓰지 않습니다. 이전 `.env`를 직접 만든 경우 Migration 계정 변수를 직접 확인합니다. `.env` 내용이나 `docker compose config`의 전체 결과를 공개하지 않습니다. `--quiet`로 문법만 확인합니다.

인증서 검증을 유지한 로컬 API 확인:

```powershell
curl.exe --cacert .secrets/tls/ca.crt --resolve portal.telecom.test:8443:127.0.0.1 https://portal.telecom.test:8443/api/health/live
python infrastructure/tools/proxy-smoke.py
```

브라우저 사용 시 직접 할 일: 관리자 권한으로 Windows hosts에 `127.0.0.1 portal.telecom.test`를 추가하고, 본인이 생성한 `.secrets/tls/ca.crt`만 현재 사용자 신뢰할 수 있는 루트 인증 기관에 등록한 뒤 `https://portal.telecom.test:8443`을 엽니다. 개인키 `ca.key`는 인증서 저장소나 서버에 배포하지 않습니다. 자동 스크립트는 hosts·OS 신뢰 저장소를 변경하지 않습니다.

프록시 테스트는 임시 API·화면 컨테이너를 사용합니다. 이 테스트가 통과해도 실제 앱 로그인·DB 세션·CSRF·인시던트 기능까지 통과한 것은 아닙니다.

## 4. 공용 PC 사양·네트워크 확인

현재 확인된 정보: PC1·PC2 준비됨, pfSense VM 사용 경험 있음, 사양·NIC·스위치 모델 미확인.

Ubuntu가 설치된 각 PC에서 저장소의 다음 파일을 실행합니다. 아직 Windows만 있다면 Ubuntu 설치·디스크 변경부터 진행하지 말고 OS와 사양부터 기록합니다.

```bash
bash infrastructure/tools/collect-host-inventory.sh
```

CPU·RAM·디스크·유선 포트 수·OS를 PC별로 정리합니다. 가상 인터페이스 수를 물리 NIC 수로 세지 않습니다. 실제 IP·장비 식별정보·로그는 공개 저장소에 원본 그대로 올리지 않습니다. 가상 NIC와 VLAN 서브인터페이스 배치는 C와 합의합니다.

장비 확인 후 B/C 작업 순서:

1. C가 주소·VLAN 트렁크·허용 포트·pfSense VM 위치를 확인합니다.
2. B가 공용 PC용 MySQL 실행 구성, 데이터 경로·볼륨 소유권·서버 ID·검증 TLS·계정을 확정합니다. 현재 실습 Compose를 공용 PC 운영 설정으로 사용하지 않습니다.
3. PC1 k3s Server+Worker, PC2 Agent 설치 버전과 옵션을 검증합니다. 토큰·kubeconfig는 서버에서 보호하며 Git에 넣지 않습니다.
4. A 이미지를 실제 SHA/digest로 빌드하고 양쪽 노드에서 접근 가능하게 발행합니다. Migration Secret과 런타임 Secret을 분리합니다.
5. Migration 1회 실행 후 Web/API를 배포합니다. C의 NetworkPolicy가 필요한 통신을 허용하는지 공동 확인합니다.
6. 호스트 Nginx 설정을 렌더링하고 NIC·인증서·Ubuntu 사용자에 맞춰 검토합니다. `nginx -t` 후 적용합니다.
7. Keepalived 예시의 NIC를 교체하고 문법·VRRP protocol 112·동일 L2·방화벽을 확인합니다. Nginx 중단 → 웹 VIP 이동 → 복구 시험 순서로 기록합니다.
8. DB는 수동 fencing·GTID 확인·승격·DB VIP 이동을 별도 시험합니다. [수동 복구 절차](../../database/runbooks/mysql-failover.md)를 따릅니다.
9. 외부 백업 매체·GPG 키·보호된 client.cnf를 준비하고 암호화 백업·분리 복원을 시험합니다. 데이터가 있는 원본에 복원하지 않습니다.

```powershell
python infrastructure/tools/render-host-nginx.py pc1
python infrastructure/tools/render-host-nginx.py pc2
kubectl kustomize infrastructure/kubernetes/base
```

위 명령은 설정 생성·렌더링만 수행합니다. 매니페스트에는 이미지 자리표시자와 미생성 Secret이 있으므로 지금 `kubectl apply`하지 않습니다. 실제 IP가 없는 현재 Windows PC에 Keepalived/Nginx 호스트 설정을 설치하지 않습니다.

## 5. 다른 담당자에게 전달할 내용

복사할 인계 문구와 필요한 파일은 [담당자 연동 계약](b-runtime-handoff.md)에 정리했습니다. 메시지 전송은 팀에서 직접 진행합니다.

## 6. 내가 직접 수정한 뒤 커밋하는 방법

`.env`, `.secrets/`, `.data/`, 키·인증서, DB 데이터·덤프·백업, kubeconfig, k3s 토큰은 커밋하지 않습니다. 실제 설정 대신 비밀값 없는 `.example`과 마스킹된 검증 기록을 올립니다.

```powershell
git status --short
git diff --check
git diff -- infrastructure/k3s/pc1-config.yaml.example infrastructure/k3s/pc2-config.yaml.example
git add infrastructure/k3s/pc1-config.yaml.example infrastructure/k3s/pc2-config.yaml.example
git diff --cached --stat
git commit -m "feat(k3s) : 공용 PC 노드 설정 확정"
git push -u origin HEAD
```

다른 작업도 해당 파일만 골라 단계별 커밋합니다.

| 작업 | 커밋할 경로 예 | 커밋 예 | 첨부 검증 |
|---|---|---|---|
| 실제 앱 빌드 수정 | infrastructure/docker/ | `build(docker) : 앱 연동 빌드 설정 조정` | 이미지 빌드·Health API |
| 공용 PC MySQL 실행 구성 | infrastructure/docker/compose/pc1 또는 pc2 | `feat(database) : 공용 PC 복제 실행 구성 추가` | GTID·읽기 전용·TLS |
| Nginx·웹 VIP | infrastructure/nginx, keepalived | `feat(ha) : 공용 PC 웹 VIP 설정 확정` | 문법·중단·복구 결과 |
| 백업 운영 | database/backup | `feat(backup) : 외부 매체 암호화 백업 구성` | 분리 복원·행/제약 비교 |
| 실행 결과 문서 | docs/operations | `docs(infra) : 공용 PC 검증 결과 기록` | 날짜·조건·PASS/미검증 구분 |

각 작업 브랜치에서 `develop` 대상으로 PR을 열고 영향 담당자의 확인 후 통합합니다. 지금 제공한 인프라 기반 PR을 합쳤다는 이유로 실제 장비 설정까지 완료했다고 표시하지 않습니다.
