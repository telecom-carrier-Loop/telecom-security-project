# 학원망 n8n 내부 API 전용 HTTPS 연결

2026-10-27 준비안. **실제 랩 적용·pfSense 변경·n8n 호출 성공은 아직 확인하지 않았다.**
자동화 담당자는 PC2 Windows Docker의 n8n(송신 주소 `192.168.3.19`)이며 전용 10443 사용에 동의했다.

## 경로와 적용 범위

```text
PC2 n8n (192.168.3.19)
  → pfSense WAN 별칭 192.168.3.30:10443 (원본 출발지 .3.19/32만 허용)
  → DNAT 192.168.7.185:30445 + SNAT 192.168.3.30
  → telecom-automation-edge (노드별 1개, externalTrafficPolicy: Local)
  → telecom-api:5000 (기존 k3s API, webuser DB 연결)
```

- 일반 웹 `https://192.168.3.30`은 계속 `/api/internal`과 `/api/internal/*`를 404로 막는다. ADMIN 페이지는 기존처럼 서버가 세션과 역할로 판정한다.
- 새 프록시는 아래 5개의 정확한 경로·메서드만 전달한다. 그 외는 404, 잘못된 메서드는 405다. 전용 입구로 고객/관리자 화면을 제공하지 않는다.
- **pfSense의 원본 Source 제한이 필수다.** SNAT 후 Nginx는 PC2 원본 대신 `.3.30`을 보므로 그 주소만 허용한다. 이 Nginx allow가 PC2 제한을 대신하지 않는다.
- NodePort의 `Local`은 출발지 보존을 위한 설정이다. 노드별 프록시가 Ready여야 해당 노드로 접근할 수 있다. 일반 PC의 직접 NodePort 호출은 허용하지 않는다.
- DB 3306, 공개 edge 설정, API Deployment/Secret, 기존 9443 규칙은 이 도구로 변경하지 않는다. 이미지 재빌드·DB migration도 필요 없다.
- 현재 관제 문서의 “공개 관리자 API 404” 부분은 ADMIN 접근 변경 이전 기록이다. 내부 API 차단과 관리자 로그인 권한을 구분한다.

| 메서드 | n8n 호출 URL | n8n Header Auth Credential에 저장할 토큰 |
|---|---|---|
| POST | `https://192.168.3.30:10443/api/internal/incident-events` | INCIDENT_API_TOKEN |
| POST | `https://192.168.3.30:10443/api/internal/ip-blocks` | AUTOMATION_API_TOKEN |
| POST | `https://192.168.3.30:10443/api/internal/account-locks` | AUTOMATION_API_TOKEN |
| GET | `https://192.168.3.30:10443/api/internal/privilege-violations` | AUTOMATION_API_TOKEN |
| POST | `https://192.168.3.30:10443/api/internal/role-revocations` | AUTOMATION_API_TOKEN |

토큰은 기존 배포값을 사용한다. 값이 같더라도 용도별 Credential을 분리한다. ADMIN 로그인 쿠키로 대체하지 않는다.

## 1. PC1 Ubuntu — 계획 생성

실행 전 두 노드와 API/공개 edge Pod가 각각 2개 Ready여야 한다.

```bash
cd "$HOME/telecom-security-project"
git fetch origin
git show origin/automation-api-ingress-20261027:infrastructure/tools/k3s-automation-ingress.py > "$HOME/k3s-automation-ingress.py"
python3 -m py_compile "$HOME/k3s-automation-ingress.py"
sudo -v
python3 "$HOME/k3s-automation-ingress.py" plan
```

`PLAN OK` 확인 후 출력의 `WORK_DIR`을 보존한다. 계획 단계는 API 컨테이너 안에서 5개 라우트의 토큰 설정 여부/선행 인증/미인증 401을 검사하며, 실제 토큰을 출력하거나 유효 토큰으로 조치를 실행하지 않는다. 기존 edge 두 Pod에서 임시 설정으로 `nginx -t`, 신규 리소스 server dry-run도 수행한다. 실제 신규 리소스는 아직 생성하지 않는다.

NodePort 30445 충돌, 기존 동명 리소스, NetworkPolicy 존재 시 중단한다. 기존 NetworkPolicy가 있다면 새 프록시→API TCP5000, DNS 및 프로브 경로를 관제/인프라 담당자가 먼저 검토해야 한다. 이 도구는 정책을 임의 완화하지 않는다.

## 2. PC1 Ubuntu — 신규 프록시 적용

```bash
loopAutomationWork="$(cat "$HOME/.telecom-automation-workdir")"
sudo -v
python3 "$HOME/k3s-automation-ingress.py" apply --work-dir "$loopAutomationWork"
python3 "$HOME/k3s-automation-ingress.py" status --work-dir "$loopAutomationWork"
sudo k3s kubectl -n telecom get pods -l app=telecom-automation-edge -o wide
```

새 Pod가 PC1/PC2에 하나씩 `1/1 Running`, Service NodePort가 30445이고 `externalTrafficPolicy: Local`인지 확인한다. 기존 공개 edge의 캐시된 이미지와 현재 TLS Secret 참조를 재사용한다. 인증서에는 `192.168.3.30` SAN이 있어야 하며 기존 공개 443에서 그 주소로 검증 성공한 상태를 전제로 한다.

`Stage: applied-needs-pfsense-n8n-tests`는 **생성 완료·연동 시험 대기**다. 중간 생성 실패 시 이 계획에서 생성한 UID/소유권이 일치하는 리소스만 자동 제거한다. 통신이 끊겨 응답을 못 받았다면 `status`로 남은 리소스와 소유권을 확인하고 무작정 재적용하지 않는다.

## 3. PC3 pfSense — PC2 전용 NAT

먼저 **Diagnostics → Backup & Restore**에서 현재 설정을 로컬 백업한다. 10443을 pfSense 관리 GUI나 다른 NAT에서 사용 중이면 적용을 중단하고 충돌을 해결한다. 기존 서비스 443 규칙을 편집하지 않고 새 규칙을 만든다.

**Firewall → NAT → Port Forward → Add**:

| 항목 | 값 |
|---|---|
| Interface / Address Family / Protocol | WAN / IPv4 / TCP |
| Source | Single host or alias → `192.168.3.19` (`/32`), Source Port Any |
| Destination | Single host or alias → `192.168.3.30` |
| Destination Port Range | Other → From `10443`, To `10443` |
| Redirect target IP | `192.168.7.185` |
| Redirect target port | Other → `30445` |
| Description | `telecom-automation-pc2-https` |
| NAT Reflection | Disable (WAN에서 받는 경로) |
| Filter rule association | Add associated filter rule |

Save → Apply Changes. **Firewall → Rules → WAN**의 연동 규칙이 Source `.3.19/32`, Destination **변환 후 주소** `.7.185:30445`인지 확인한다. Gateway는 default, Log를 켠다. 기존 같은 인터페이스 왕복 경로처럼 **Advanced Options → Disable reply-to**를 켠다. `reply-to`를 pfSense 셸 명령으로 직접 입력하지 않는다.

**Firewall → NAT → Outbound**: 현재 Hybrid 모드를 유지하고 최상단에 추가한다.

| 항목 | 값 |
|---|---|
| Interface / Address Family / Protocol | WAN / IPv4 / TCP |
| Source | Network `192.168.3.19/32`, Port Any |
| Destination | Network `192.168.7.185/32`, Port `30445` |
| Translation Address | Other subnet → `192.168.3.30/32` |
| Translation Port / Static Port | 비움 / 해제 |
| Description | `telecom-automation-pc2-SNAT` |

Save → Apply Changes. 공통 Any 출발지 규칙으로 바꾸지 않는다. 기존 연결이 남았다면 **Diagnostics → States**에서 이번 `.3.19 → .3.30:10443` 연결만 찾아 삭제 후 다시 시험한다. 전체 State를 초기화하지 않는다.

## 4. PC2 Windows PowerShell — 네트워크/CA 확인

```powershell
Test-NetConnection 192.168.3.30 -Port 10443
curl.exe --noproxy "*" --ssl-revoke-best-effort --connect-timeout 3 --max-time 10 -sS -i -X POST -H "Content-Type: application/json" --data '{}' "https://192.168.3.30:10443/api/internal/incident-events"
curl.exe --noproxy "*" --ssl-revoke-best-effort --connect-timeout 3 --max-time 10 -sS -i "https://192.168.3.30/api/internal/privilege-violations"
```

기대값: TCP True → **전용 포트 미인증 API 401 JSON** → **일반 443 내부 API 404**. API 401은 네트워크/TLS/정확한 라우트 전달이 된 상태다. 토큰 없이 브라우저로 POST URL을 여는 것은 시험이 아니며 GET이므로 405가 맞다.

Windows curl의 CA 신뢰와 n8n Node.js의 CA 신뢰는 별개다. curl이 인증서 오류 60이면 이전에 검증한 **공개 `lab-ca.crt`**의 지문을 대조하고 Windows 현재 사용자 Root에 등록한다. 개인키는 복사하지 않는다. `-k`로 성공 기준을 대체하지 않는다.

## 5. PC2 n8n — 컨테이너 CA와 HTTP Request 노드

먼저 컨테이너 이름과 실제 Compose 파일 위치를 확인한다(이 명령은 토큰 환경변수를 출력하지 않는다).

```powershell
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
# 실제 컨테이너 이름으로 n8n을 바꾼다.
docker inspect n8n --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}'
```

Compose로 운영 중이라면 **기존 파일의 n8n 서비스**에 아래 항목만 합친다. 예시는 완성된 Compose가 아니다. 기존 데이터 볼륨, DB, `N8N_ENCRYPTION_KEY`, 네트워크, 기존 환경변수를 유지한다. `pki/lab-ca.crt`에는 검증된 PEM 형식 공개 CA만 둔다.

```yaml
services:
  n8n:
    environment:
      NODE_EXTRA_CA_CERTS: /opt/telecom-ca/lab-ca.crt
    volumes:
      - ./pki/lab-ca.crt:/opt/telecom-ca/lab-ca.crt:ro
```

실제 Compose 디렉터리에서 실제 서비스 이름으로 `docker compose up -d --no-deps n8n`을 실행한다. 여러 `-f` 파일로 운영하면 기존과 같은 `-f` 목록을 사용한다. Compose가 아닌 `docker run` 배포라면 기존 실행 정의·데이터 마운트를 먼저 확보해 같은 CA 마운트/환경변수를 추가하여 재생성해야 한다. 확인 없이 컨테이너/볼륨을 삭제하거나 새 n8n을 만들지 않는다. `NODE_EXTRA_CA_CERTS`는 프로세스 시작 때 읽는다.

CA 파일 확인과 실제 n8n 컨테이너 내부 HTTPS 시험(토큰 없이 읽기 라우트, 결과 401 기대):

```powershell
docker exec n8n node -e 'const fs=require("fs"); console.log("CA file readable:", fs.existsSync("/opt/telecom-ca/lab-ca.crt"));'
docker exec n8n node -e 'const https=require("https"); const q=https.get("https://192.168.3.30:10443/api/internal/privilege-violations",r=>{console.log("HTTP",r.statusCode);r.resume();if(r.statusCode!==401)process.exitCode=1;}); q.setTimeout(10000,()=>q.destroy(new Error("timeout")));q.on("error",e=>{console.error(e.code||e.message);process.exitCode=1;});'
```

HTTP Request 노드에서:

1. 위 표의 URL/메서드로 변경한다. 기존 본문과 이벤트 ID 생성 방식은 유지한다.
2. Authentication → Generic Credential Type → Header Auth. 헤더 이름 `X-API-Key`, 값에는 해당 기존 토큰을 **Credential 화면에서만** 넣는다. Bearer 방식이면 기존 방식 하나만 사용한다.
3. POST의 Content-Type은 JSON, Send Body는 JSON. `X-Workflow`에는 기존 워크플로 식별자를 유지한다.
4. `Ignore SSL Issues`는 끈다. 브라우저 로그인 쿠키를 전달하지 않는다.
5. 먼저 토큰이 필요한 조회 `privilege-violations`를 1회 호출하여 200을 확인한다. 이 조회도 위반 보안 이벤트/감사 기록을 만들 수 있으므로 주기 반복 시험은 피한다.
6. 담당자와 합의한 **실습 이벤트·시험 IP·시험 CUSTOMER 계정**으로 각 변경 API를 검증한다. incident-events는 첫 호출 201, 같은 source/event_id와 같은 본문 재전송 200(중복), 다른 본문 409가 기준이다. IP차단/계정잠금/역할회수는 실제 상태를 바꾸므로 운영 계정으로 임의 시험하지 않는다.
7. 웹 ADMIN의 인시던트/자동화 기록과 n8n 실행 결과를 대조한다. Discord 전송 성공은 별도로 확인한다. 토큰이나 전체 자격증명을 GitHub·스크린샷에 남기지 않는다.

## 6. 일반 PC 차단 시험과 장애 구분

PC1·PC2·PC3 이외 시험 PC의 PowerShell에서:

```powershell
Test-NetConnection 192.168.3.30 -Port 10443
curl.exe --noproxy "*" --ssl-revoke-best-effort --connect-timeout 3 --max-time 10 -sS -i "https://192.168.3.30/api/internal/privilege-violations"
Test-NetConnection 192.168.3.18 -Port 3306
Test-NetConnection 192.168.3.19 -Port 3306
```

기대값: **10443 TCP False, 443 내부 API 404, 두 DB TCP False**. 일반 웹/ADMIN 세션별 권한 확인도 기존처럼 계속 성공해야 한다.

| 결과 | 확인할 곳 |
|---|---|
| PC2 TCP10443 실패 | pfSense WAN 패킷/규칙 로그, Source3.19/32, NAT 목적지3.30, 10443 충돌 |
| TCP 성공·TLS 실패 | 현재 인증서 SAN3.30/유효기간, PC2 또는 n8n CA 저장소 |
| 전용 포트 403 | 신규 SNAT 적용 여부, Service Local, edge access log의 실제 remote_addr |
| 전용 포트 404/405 | URL 정확성, 메서드, 잘못된 upstream/이전 API 이미지 |
| 전용 포트 401 | 네트워크 정상; n8n Credential의 토큰 종류·값 확인(출력 금지) |
| 503 INTEGRATION_DISABLED | 해당 API 배포의 토큰 설정 여부 |
| 502/504 | API Ready 2개, API Service endpoint 및 DB 연결 |
| 422/409 | 인증 후 본문 유효성/중복·업무 조건 확인 |
| 일반 PC TCP10443 성공 | 완료 처리 금지; pfSense의 광범위 pass/NAT 규칙 및 기존 state 검사 |

PC1 Ubuntu 진단:

```bash
sudo k3s kubectl -n telecom get pods -l app=telecom-automation-edge -o wide
sudo k3s kubectl -n telecom describe deployment telecom-automation-edge
sudo k3s kubectl -n telecom logs -l app=telecom-automation-edge -c edge --tail=40 --prefix=true
sudo k3s kubectl -n telecom get endpointslices -l kubernetes.io/service-name=telecom-api
```

## 되돌리기 — 문제가 생긴 경우에만

pfSense에서 **이번에 추가한** 10443 Port Forward/연동 규칙과 해당30445 SNAT만 비활성화·적용한다. 기존443/9443 규칙은 유지한다. PC1 Ubuntu:

```bash
loopAutomationWork="$(cat "$HOME/.telecom-automation-workdir")"
sudo -v
python3 "$HOME/k3s-automation-ingress.py" rollback --work-dir "$loopAutomationWork"
python3 "$HOME/k3s-automation-ingress.py" status --work-dir "$loopAutomationWork"
```

공개 edge/TLS Secret/API/DB에는 되돌릴 변경이 없다. 성공 후 rollback을 추가로 실행할 필요는 없다. 재시도하려면 삭제 완료를 확인한 뒤 **새 작업 폴더로 plan**을 생성한다.

## 근거

- [pfSense Port Forward](https://docs.netgate.com/pfsense/en/latest/nat/port-forwards.html): 원본 Source 제한과 연동 필터 규칙.
- [Kubernetes Source IP](https://kubernetes.io/docs/tutorials/services/source-ip/): NodePort Local의 출발지 보존.
- [Node.js NODE_EXTRA_CA_CERTS](https://nodejs.org/api/cli.html#node_extra_ca_certsfile): 추가 CA와 프로세스 시작 시 읽기.
- [n8n 사용자 CA](https://docs.n8n.io/hosting/configuration/configuration-examples/custom-certificate-authority/): n8n에도 별도 CA 신뢰가 필요하며 공개 PEM 인증서만 사용한다.
