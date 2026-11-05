# 공개 HTTPS의 실제 출발지 전달과 재배포

작성일: 2026-11-05. 대상: pfSense HAProxy TCP 전달, 두 k3s 노드, 공개 Nginx edge.

## 변경 이유와 경계

기존 TCP 프록시 경로에서는 웹/API가 pfSense 주소를 출발지로 기록했다. HAProxy가 받은 출발지를 PROXY protocol v2로 전달하고, Nginx가 정확한 프록시 peer만 신뢰한 뒤 `X-Forwarded-For`를 덮어쓰도록 별도 edge를 구성한다. 앱 인증·ADMIN 권한·DB·n8n 보호 IP 목록을 변경하는 작업은 아니다.

```text
공개 HTTPS → HAProxy TCP/PROXY v2
           → 각 노드 NodePort 31443 (Local)
           → telecom-edge-proxytest:8445 (TLS + PROXY)
           → 기존 노드 로컬 Web/API 서비스 → API 보안 이벤트 → Wazuh
```

WSL이 Windows NAT를 거치면 보존되는 주소는 Windows 측 출발지다. WSL 내부 주소를 복원하거나 실행 옵션의 `KALI_IP` 값을 실제 출발지로 만드는 기능이 아니다. 공유 NAT 주소나 인프라 보호 IP를 임의로 차단 목록 대상으로 바꾸지 않는다.

## 이미 적용된 현장

현재 사용 중인 시험 이름을 운영 인계에서도 유지한다.

| 리소스 | 용도 |
|---|---|
| `telecom-edge-proxytest` Deployment | 두 노드에 각각 한 Pod |
| `telecom-edge-proxytest-config` ConfigMap | 기존 8443 서버와 새 8445 서버 |
| `telecom-edge-proxytest` Service | 31443 → 8445, `externalTrafficPolicy: Local` |
| HAProxy `telecom-public-proxy-test` Backend | 두 노드 31443, 서버별 PROXY v2 |

이미 이 세 리소스가 있으면 생성 도구를 다시 실행하지 않는다. 기존 리소스가 있으면 도구는 중단하도록 작성됐다. 공개 443의 Default Backend가 위 Backend를 가리키는 동안 `proxytest` 리소스를 삭제하면 공개 웹이 중단될 수 있다. 이름 변경·기존 edge 통합은 별도 전환 작업이다.

현재 웹/API 재배포에는 edge를 다시 생성하거나 앱 이미지를 다시 만들 필요가 없다. 이 PR을 병합하는 것만으로 실행 중인 클러스터·pfSense가 변경되지는 않는다. 다음 앱 릴리스부터 이 PR이 포함된 준비/검증 도구를 사용한다.

## 새 환경에서 생성할 때만: PC1 Ubuntu

저장소 루트에서 실행한다. pfSense의 실제 backend 연결 peer를 비공개 인계 자료와 현장 관측으로 확인한다. VIP나 클라이언트 IP를 대신 넣지 않는다.

```bash
read -r -p 'Observed pfSense backend peer IPv4: ' PFSENSE_PEER_IP
python3 infrastructure/tools/loop-client-ip-test.py plan --proxy-ip "$PFSENSE_PEER_IP"
```

계획 단계는 기존 공개 ConfigMap/Deployment/Service와 두 Ready 노드를 읽는다. 실제 이미지·TLS Secret 참조·보안 설정·기존 8443 probe와 로컬 upstream을 복제하며 Secret 객체를 읽지 않는다. 원래 공개·관리·자동화 리소스를 수정하지 않는다. 두 실행 edge에서 고유 임시 설정의 `nginx -t`와 서버 dry-run을 통과해야 계획 파일을 만든다.

계획은 홈 폴더의 비공개 작업 디렉터리에 저장된다. 원본 resourceVersion·UID와 후보 체크섬을 확인하고 새 세 리소스만 생성한다.

```bash
python3 infrastructure/tools/loop-client-ip-test.py apply
sudo k3s kubectl -n telecom get pods -l app=telecom-edge-proxytest -o wide
```

기존 시험 이름·31443 점유·NetworkPolicy·알 수 없는 설정·노드/이미지 차이·계획 후 원본 변경은 자동으로 덮어쓰지 않고 중단한다. 일부 생성 후 실패하면 작업 디렉터리의 생성 기록을 점검한다. 원본을 자동 복구하거나 시험 리소스를 자동 삭제하지 않는다.

8443 서버는 기존 readiness/liveness probe용으로 보존한다. 새 Service의 트래픽은 8445로만 보낸다. 새 서버는 다음 세 조건을 함께 가진다.

- `listen 8445 ssl proxy_protocol;`
- 관측한 단일 peer의 `/32`만 `set_real_ip_from`으로 신뢰하고 `real_ip_header proxy_protocol;` 사용.
- 원래 socket peer를 `$realip_remote_addr`로 검사하여 다른 peer는 403 처리.

복원된 `$remote_addr`로 `X-Forwarded-For`를 덮어쓰며 클라이언트가 직접 보낸 헤더를 신뢰하지 않는다. 두 서버 모두 기존 공개 관리자/내부 API 404와 노드 로컬 upstream을 유지한다. TLS Secret·인증서 파일을 저장소에 복사하지 않는다.

## pfSense: 시험 입구부터 전환

1. 변경 전 pfSense 전체 구성을 비공개로 백업하고 원래 443 Default Backend를 기록한다.
2. 기존 Backend를 별도 복제하여 `telecom-public-proxy-test`로 만든다. 기존 공통 Backend에서 PROXY 옵션을 바로 켜지 않는다.
3. 두 backend 서버의 주소는 유지하고 포트를 31443으로 설정한다. 각 **서버 행의 상세 Advanced**에 아래 값을 넣는다.

   ```text
   send-proxy-v2 check-send-proxy
   ```

4. TCP/TLS passthrough를 유지한다. 데이터 연결에 추가 SSL 암호화를 켜지 않는다. 기존 TLS 상태 검사와 CA 검증은 유지한다. 상태 검사의 올바른 포트·PROXY 전송과 `/api/health/ready`의 200을 확인한다.
5. 시험 Frontend 11443만 새 Backend로 연결하여 Save/Apply 후 두 서버 UP을 확인한다. WAN 규칙은 승인된 시험 출발지에서 해당 VIP·시험 포트로만 허용한다.
6. 아래 검증을 통과한 뒤 공개 443 Frontend의 Default Backend만 새 Backend로 바꾸고 Save/Apply 한다. 관리/자동화 NAT나 방화벽 전체를 변경하지 않는다.

PROXY 송신과 수신은 한 쌍이다. 기존 8443으로 `send-proxy-v2`를 보내거나 새 8445에 PROXY 없이 연결하면 정상 HTTPS가 되지 않는다. Nginx의 peer 검사도 네트워크 방화벽을 대체하지 않는다.

## 현장 검증

CA를 확인한 클라이언트에서 `curl --cacert <확인된-CA-파일>`을 사용한다. `-k`로 성공 판정을 대신하지 않는다.

| 요청 | 기대 결과 |
|---|---|
| `/` | 200 |
| `/api/health/ready` | 200, `database: ok`, `status: ok` |
| `/api/auth/me` 미인증 | 401 |
| `/admin`, `/api/admin/dashboard`, `/api/internal/privilege-violations` | 404 |

시험 11443과 전환 후 정식 443을 각각 확인한다. `/api/health/ready/`처럼 임의로 뒤에 `/`를 붙이지 않는다. 두 Backend의 UP만으로 요청 출발지 보존이나 ADMIN 권한까지 검증됐다고 판단하지 않는다.

가상 계정의 로그인 실패 **한 건**으로 요청 ID를 얻고 PC1 Ubuntu에서 확인한다. 명령에는 응답으로 받은 실제 ID를 넣는다.

```bash
sudo k3s kubectl -n telecom logs -l app=telecom-api --all-containers=true --since=15m --tail=2000 --prefix=true | grep -F 'REPLACE_WITH_REQUEST_ID'
```

같은 요청의 `auth.login.failed`와 `http.request`의 `evidence.src_ip`가 실제 출발지와 일치해야 한다. 보안 이벤트의 `event_id`도 별도로 대조한다.

PC2 Windows PowerShell의 Wazuh 확인 예:

```powershell
docker exec wazuh-manager sh -c "grep -F 'REPLACE_WITH_SOURCE_IP' /var/ossec/logs/alerts/alerts.json | grep -i 'login' | tail -n 3"
```

수집기는 API 보안 로그를 `login-bruteforce` 형태로 변환하고 `request_id`를 생략할 수 있다. 이 경우 API와 Wazuh의 **동일한 event_id·발생 시각·src_ip**로 연결한다. 마지막 몇 건만 보면 주기적 패킷 통계가 로그인 기록을 가릴 수 있다. 검색 결과 없음만으로 수집 실패를 단정하지 않는다.

`110684`는 수집/상관 분석용 기본 기록이며, 이 경보만으로 반복 공격 탐지·n8n 전달·차단 성공을 주장하지 않는다. n8n의 선택된 경로, 보호 IP 제외, 실제 차단 요청/응답과 새 요청의 `403 IP_BLOCKED`는 별도 확인한다. health는 차단 예외일 수 있어 health 200으로 차단 실패를 판단하지 않는다.

## 재배포·복구

- 이 PR의 릴리스 도구는 기존 공개 edge 검사에 더해, `telecom-edge-proxytest`가 있으면 Service의 Local/포트/selector, 새 ConfigMap, 두 실행 Pod의 정확한 peer·PROXY listener·기존 차단 보존까지 **읽기 전용** 검사한다. 시험 edge가 없는 기존 환경은 기존 검사를 유지한다.
- 준비 도구는 같은 커밋의 `loop-client-ip-test.py`도 두 VM에 전달한다. 누락된 패키지는 검사를 생략하지 않고 다시 만든다. 새 검증 도구를 현장에 실행한 결과는 아직 별도 확인 대상이다.
- 앱 릴리스는 기존 Web/API Deployment를 업데이트한다. 이 도구는 HAProxy를 조회/변경하지 않으며 실제 443 연결 대상도 자동 증명하지 않는다. 전환 후 외부 HTTPS와 로그 검증은 계속 필요하다.
- 시험 edge는 생성 당시의 이미지와 설정을 보존한다. 기존 edge의 ConfigMap 변경이 자동 동기화되지 않는다. edge 이미지/인증서 참조/정책 갱신은 활성 경로를 확인한 별도 순차 전환으로 관리한다.
- 복구는 pfSense 443 Frontend의 Default Backend를 기록해 둔 원래 Backend로 되돌리고 Save/Apply한 뒤 고객 웹·DB 준비·공개 관리자 차단을 확인한다. 원래 Backend의 30443/비-PROXY 설정도 함께 유지해야 한다.
- 443과 11443 모두 시험 Backend를 참조하지 않고 복구 검증이 끝나기 전에는 시험 리소스를 삭제하지 않는다. `rollout undo`만으로 ConfigMap이나 pfSense Backend가 복원되지는 않는다. 원시 백업·생성 계획·로그·CA/개인키는 비공개 보관한다.

## 참조

- [HAProxy PROXY protocol](https://www.haproxy.com/documentation/haproxy-configuration-tutorials/proxying-essentials/client-ip-preservation/enable-proxy-protocol/)
- [Nginx real IP 모듈과 원래 peer](https://nginx.org/en/docs/http/ngx_http_realip_module.html)
- [앱 릴리스](webapi-clean-release.md), [공개 관리자 차단](academy-admin-access.md)
