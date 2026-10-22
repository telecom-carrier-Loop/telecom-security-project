# 2026-10-22 k3s 웹 배포 작업 기록과 pfSense 인계

기준일은 2026-10-22, 시간대는 Asia/Seoul이다. 사용자 제공 실행 화면과 저장소 코드를 기준으로 작성했다. 아래의 확인 완료, 구성한 값, 미검증 항목을 구분한다. 이 문서는 비밀번호·가입 토큰·Secret 내용·SQL 백업·인증서를 포함하지 않는다.

## 현재 결과

`http://localhost:18080/admin/customers`에서 로그인 후 실제 회원 목록이 표시되고, 관측된 `customers`, `support`, `incidents`, `monitoring-links`, `automation-status` 요청이 HTTP 200으로 응답했다. 이 경로는 Kubernetes에 배포한 React/Nginx → Flask → 기존 MySQL을 사용한다. 모니터링 링크 API의 200은 Wazuh·Grafana 등 외부 화면 자체의 연결 성공을 뜻하지 않는다.

현재 진입점은 개발 검증용 SSH·kubectl 포트 전달이다. pfSense 경유, 외부 HTTPS, 웹 진입점 이중화, PC 전체 장애 대응을 완료한 상태는 아니다. pfSense는 다른 팀원이 2026-10-23 진행할 예정이며 주소와 연결 방식은 미확정이다.

## 실제 주소와 역할

| 대상 | 주소 / 구성 | 확인 범위 |
|---|---|---|
| PC1 Ubuntu VM | `pc1-k3s`, `192.168.7.185/24`, `br0` | k3s Server + Worker, 노드 Ready |
| PC2 Ubuntu VM | `pc2-k3s`, `192.168.7.100/24`, `br0` | k3s Agent/Worker, 노드 Ready |
| k3s | 양쪽 `v1.36.5+k3s1`, 기본 containerd | 노드 목록에서 버전 일치 확인 |
| VM 사양 | 각 2 vCPU / 약 4 GiB RAM / 가상 디스크 60 GB | 실제 `/` 파일시스템은 약 29 GB였으므로 디스크 전체가 확장됐다고 보지 않음 |
| PC1 Windows MySQL | `192.168.3.18:3306`, `flask_mysql` | 두 노드 Pod TCP·업무 조회 성공. 앱 연결로 8.4.11 / server_id 1 / 두 읽기 전용 값 0 확인 |
| PC2 Windows MySQL | 기존 `192.168.3.19:3306`, `mysql-lab` | 22:25 KST 예약 시험의 Replica 보호 검사·백업 성공. Windows IP 재조회·직접 복제 상태/지연 출력은 없음 |
| 앱 DB | `my_new_board_db` | 오늘 사용한 접속 계정은 `root`; 앱 전용 계정 분리 필요 |
| PC3 pfSense VM | WAN/LAN 주소·어댑터 연결 미확정 | 내일 네트워크 담당자가 설계·설정 |

VM 주소는 마지막 네트워크 화면에서 DHCP 할당이었다. DHCP 예약/승인된 고정 IP 설정의 완료 증거는 아직 없다. Windows DB 주소 `192.168.3.x`와 Ubuntu 노드 주소 `192.168.7.x`를 혼동하지 않는다. pfSense를 위해 k3s 노드 IP·기본 경로를 먼저 바꾸지 않는다.

## 오늘 진행한 작업

1. VMware VMnet0를 실제 유선 어댑터에 연결하고 Ubuntu의 `br0`에 IP를 할당했다. 클론 VM의 hostname·식별자 중복을 정리해 두 노드의 IP와 브리지 MAC을 분리했다.
2. 양쪽 VM 시간 동기화와 UFW 비활성 상태를 확인하고 Swap을 끄는 기준으로 설치를 진행했다. 재부팅 후 Swap 유지 여부는 운영 재개 시 다시 확인한다.
3. PC1 Server와 PC2 Agent를 같은 k3s 버전으로 연결했다. 잘못 PC1에서 시작한 별도 `k3s-agent` 서비스는 중지하도록 조치했으며 사용자에게 해결 완료를 확인받았다. Server에 포함된 Worker 기능과 별도 Agent 서비스는 구분한다.
4. `k3s-smoke` 네임스페이스에 웹 Pod 두 개를 서로 다른 노드에 배치했다. DNS·Service 응답을 확인했고 PC2 테스트 Pod 삭제 후 새 Pod의 `1/1 Running`을 확인했다.
5. VM 소스를 Windows로 전달해 기존 배포용 Dockerfile로 Flask·React 이미지를 빌드했다. React의 미사용 `MonitoringLinks` import로 발생한 TS6133을 한 줄 제거로 수정했다. [PR #22](https://github.com/telecom-carrier-Loop/telecom-security-project/pull/22)의 수정은 문서 작성 시 최신 main에 포함돼 있다.
6. React 이미지 빌드와 `nginx -t` 성공을 확인했다. Docker 이미지 tar를 두 VM의 containerd에 반입하고 두 노드의 이미지 ID가 일치함을 확인했다.
7. 각 노드에 별도 `db-net-pc1`, `db-net-pc2` Pod를 실행해 `192.168.3.18:3306` TCP 연결 성공을 확인했다. 이 TCP 시험 자체는 DB 인증 시험이 아니다.
8. 기존 환경에서 DB 접속 정보와 이벤트·자동화 토큰을 읽어 ConfigMap·Secret으로 등록했다. 화면에는 값 자체를 출력하지 않았다. Flask 두 Pod가 각각 PC1·PC2에서 `1/1 Running`이며 재시작 0회인 화면을 확인했다.
9. React/Nginx에서 `/api/`를 Flask Service로 전달하도록 구성한 뒤 새 진입 주소에서 로그인과 회원 목록 조회, 관측된 관리자 API의 200 응답을 확인했다.
10. Flask Pod의 기존 앱 연결로 PC1 DB 버전 8.4.11, server_id 1, `read_only=0`, `super_read_only=0`, `CURRENT_USER()=root@%`를 확인했다. Windows 컨테이너 내부 `root@localhost` 조회는 두 PC에서 인증 오류 1045가 나서 해당 직접 조회는 미완료다. 비밀번호 변경이나 복제 재구성은 하지 않았다.
11. PC2 Windows의 저장된 백업 계정으로 예약 상태와 실제 Test 성공을 확인했다. Status의 최근 성공은 22:14:17~22:14:20 KST, 새 Test는 22:25:11~22:25:13 KST였다. 작업 상태 Ready, 결과 0, last-run/last-success success, 다음 예약 23:14:14 KST를 확인했다. Test는 실제 새 백업을 생성했으며 최신 덤프의 RestoreTest를 실행한 것은 아니다.

별도 Agent 정리, 이미지 반입, 설정 등록, 웹 배포는 현장 VM에서 실행됐다. 이 문서 작성에 사용한 로컬 PC가 원격 VM을 직접 조작하거나 MySQL을 변경한 것은 아니다.

## 이미지와 Kubernetes 구성

| 항목 | 현재 구성 |
|---|---|
| Flask 이미지 | `docker.io/library/telecom-backend:k3s-v1`, 관측 ID `28c4a27da650`, 약 83.9 MB |
| React 이미지 | `docker.io/library/telecom-frontend:k3s-v1`, 관측 ID `5aa6cb5bd91a`, 약 26.1 MB |
| 빌드 파일 | `infrastructure/docker/backend/Dockerfile`, `infrastructure/docker/frontend/Dockerfile` |
| 앱 네임스페이스 | `telecom` |
| Flask Deployment / Service | `telecom-api`, 복제본 2, ClusterIP 5000 |
| React Deployment / Service | `telecom-web`, 복제본 2로 구성, ClusterIP 80 |
| 일반 설정 | ConfigMap `telecom-runtime` |
| DB 비밀번호·토큰 등 | Secret `telecom-api-secrets` |
| Nginx 설정 | ConfigMap `telecom-web-config`, `default.conf`를 `subPath`로 연결 |
| 이미지 정책 | 현장 배포 사본은 `imagePullPolicy: Never`; 실행할 모든 노드에 해당 이미지를 먼저 반입해야 함 |
| 노드 배치 | 앱별 필수 Pod anti-affinity로 각 노드에 하나씩 배치하도록 구성 |

Flask 두 Pod의 Ready는 화면으로 확인했다. React는 복제본 2 설정과 브라우저 서비스 성공을 기록했으나 최종 전체 Pod 목록 화면은 별도 첨부되지 않았다. 인계받는 사람이 아래 조회로 네 Pod의 현재 상태와 배치를 확인한다. 이미지의 짧은 ID는 실행 화면 대조용이며 레지스트리의 검증된 manifest digest를 대신하지 않는다. 같은 `k3s-v1` 태그를 새 내용으로 덮어쓰지 말고 다음 빌드는 새 태그를 사용한다.

저장소 `infrastructure/kubernetes/base/` 전체를 그대로 적용한 것이 아니다. 현장 작업 파일은 PC1 Ubuntu의 다음 위치다.

```text
/home/loop/k3s-app/api-deployment.yaml
/home/loop/k3s-app/web-deployment.yaml
/home/loop/k3s-app/web-config.yaml
```

API·Web Deployment는 base의 보안 설정·상태 검사·배치 설정을 유지하고 현장 이미지로 변경했다. Web에는 Nginx 설정 마운트를 추가했다. 두 Service는 ClusterIP로 생성했다. base의 예제 DB `192.168.30.100/telecom`, GHCR 자리표시자, NodePort 30500/30080을 현재 적용값으로 간주하지 않는다. k3s 설치 시 기본 Traefik·ServiceLB는 제외하는 설정을 사용했다.

현재 일반 설정은 `APP_ENV=lab`, DB 호스트 `192.168.3.18`, 포트 3306, DB 이름 `my_new_board_db`, 계정 `root`, `TRUSTED_PROXY_HOPS=1`이다. 앱 쓰기는 PC1 DB를 향한다. API Pod의 `127.0.0.1`은 Windows DB를 의미하지 않는다.

현장 Nginx 설정의 핵심은 다음과 같다. 변경 시에는 현장 파일·ConfigMap·Deployment 상태를 확인한 뒤 반영한다.

```nginx
server {
    listen 80;
    server_name _;
    root /usr/share/nginx/html;
    index index.html;

    location /api/ {
        proxy_pass http://telecom-api:5000;
        proxy_http_version 1.1;
        proxy_set_header Host $http_host;
        proxy_set_header X-Forwarded-Host $http_host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Request-ID $request_id;
        proxy_connect_timeout 3s;
        proxy_read_timeout 30s;
    }

    location / {
        try_files $uri $uri/ /index.html;
    }
}
```

## 다시 확인하고 임시 접속하기

### PC1 Ubuntu: 상태 조회

```bash
hostname
sudo k3s kubectl get nodes -o wide
sudo k3s kubectl -n telecom get deployments
sudo k3s kubectl -n telecom get pods -o wide
sudo k3s kubectl -n telecom get services
sudo k3s kubectl -n telecom get configmap telecom-runtime telecom-web-config
sudo k3s kubectl -n telecom get secret telecom-api-secrets
```

Secret 조회는 위와 같이 이름·타입·키 개수만 확인한다. `-o yaml/json`, 환경변수 전체 출력, 가입 토큰·SQL 백업의 공개 첨부는 하지 않는다. private 복원 자료는 별도 보호 경로에 보관한다.

### PC1 Ubuntu: 포트 전달

```bash
sudo k3s kubectl -n telecom port-forward service/telecom-web 18080:80 --address=127.0.0.1
```

이 터미널을 유지한다. 다른 Ubuntu 명령은 새 터미널에서 실행한다.

### PC1 Windows PowerShell: SSH 터널

```powershell
ssh -o ExitOnForwardFailure=yes -N -L 127.0.0.1:18080:127.0.0.1:18080 loop@192.168.7.185
```

이 PowerShell도 유지하고 Windows Chrome에서 `http://localhost:18080`에 접속한다. 개발 서버용 `localhost:15173`과 구분한다. localhost 접속은 현재 Chrome에서 Secure 쿠키 동작을 확인한 임시 검증 방법이며 외부 서비스 주소에는 HTTPS가 필요하다.

포트 전달은 Service 이름을 사용해도 선택된 Web Pod 하나에 연결된다. 그 Pod가 종료되면 전달 명령을 다시 실행해야 한다. 따라서 이 진입점으로 웹 노드 자동 전환·무중단을 판정하지 않는다.

## 완료와 미검증의 경계

| 항목 | 상태 |
|---|---|
| 두 k3s 노드 Ready·동일 버전 | 확인 완료 |
| 테스트 앱 DNS·Service 응답·PC2 테스트 Pod 재생성 | 확인 완료 |
| 두 노드 이미지 ID 일치 | 확인 완료 |
| 두 노드 Pod → DB TCP | 확인 완료 |
| Flask 두 Pod Ready·DB 준비 검사 | 확인 완료 |
| 새 주소의 로그인·회원 목록·관측된 관리자 API 200 | 확인 완료 |
| PC1 DB 쓰기 역할, PC2 예약 백업의 Replica 보호 검사·새 백업 | 22:25 KST 후속 확인 완료 |
| 실제 `telecom-api` Pod 삭제 후 재생성·세션 유지 | 명령 안내까지 진행, 결과 미수신 |
| 전체 앱 Pod의 최종 목록·재부팅 후 유지 | 추가 확인 필요 |
| 요청 분산 비율·장애 중 실패 건수·복구 시간 | 미측정 |
| PC 전체 장애·단일 control plane 장애 | 미검증 |
| 오늘 새로 수행한 DB 승격·원복·복제 지연 수치 검사·최신 덤프 RestoreTest | 없음 |
| pfSense·외부 HTTPS·강제 경유·차단 정책·외부 저장장치 | 미구성/미검증 |

PC1이 유일한 control plane이다. PC1 전체 장애에 대한 관리 기능 이중화는 없다. DB Primary도 같은 물리 PC1에 있으므로 PC1 전체 장애 때 Kubernetes 설정을 바꿔 DB를 전환할 수 있다고 가정하면 안 된다. 필수 anti-affinity 때문에 노드 하나가 사라졌을 때 두 번째 같은 앱 Pod가 남은 노드에 무조건 재배치되는 구성도 아니다. MySQL 복제·백업과 Kubernetes의 Pod 복구는 별개의 기능이다.

## 2026-10-23 pfSense 담당자 인계

이번 실습은 VLAN 5개를 먼저 구성하던 계획에서 변경됐으며, 현재는 VLAN 없이 k3s 웹을 먼저 구성했다. 과거 VLAN/VIP 문서는 설계 이력이다. 새 연결 방식을 확정하기 전에 기존 예제 주소로 장비를 재설정하지 않는다.

1. PC3 pfSense의 WAN/LAN 주소·프리픽스·가상 NIC·VMware VMnet 연결, 실제 물리 NIC와 학원망 정책을 확인한다. PC3의 Host-only 네트워크가 다른 PC의 VMnet과 자동으로 연결되는 것은 아니다.
2. 현재 노드 IP·DB IP를 유지할 수 있는 진입 경로를 우선 설계한다. 일반적인 WAN/LAN 라우팅은 대역을 구분하며 다른 장치와 IP를 중복 배정하지 않는다. 현재 DHCP 주소 유지 방법도 확정한다.
3. 외부에서 사용할 노드 진입 방식, TLS 종료 위치, DNS/접속 주소를 결정한다. 현재 두 앱 Service는 ClusterIP이고 NodePort/LB 진입점은 아직 만들지 않았다. Pod IP·ClusterIP를 pfSense의 고정 백엔드 주소로 임의 지정하지 않는다.
4. pfSense를 실제로 통과하는 트래픽에 정책을 적용하고, 같은 학원망에서 노드 포트로 우회하는 접근은 노드 방화벽 등에서도 제한한다. 허용할 k3s 노드 간 통신과 DB 복제 경로를 함께 보존한다.
5. HTTPS 종료 위치에 맞춰 Host·Origin·`X-Forwarded-Proto`·클라이언트 IP와 신뢰 프록시 설정을 검증한다. 현재 Web Nginx는 `$scheme`을 전달하므로 앞단에서 TLS를 종료하고 HTTP로 넘기면 Flask에 `http`가 전달될 수 있다. 홉 수만 임의 증가시키지 말고 신뢰할 발신자와 헤더 재작성 규칙을 함께 정한다.
6. 현재 임시 경로는 `/admin`과 `/api/internal`을 외부 경계에서 차단하지 않는다. 공개·관리·자동화 API의 허용 대상을 분리하고 이벤트 토큰 검증을 포함해 실제 허용/거부를 시험한다.
7. 실제 HTTPS 진입점에서 재로그인, 양 노드 서비스, 노드/Pod 장애, 우회 차단과 모니터링 로그를 확인한다. 관리자 허용 작업만 사용하고 임의의 비멱등 요청 재시도를 켜지 않는다.

계정 분리·DB 전환·백업의 후속 요구사항은 [MySQL k3s 이전 영향 점검](../runbooks/mysql84-k3s-impact.md)을 함께 인계한다.

## 다음 역할 분담

| 담당 | 다음 작업 |
|---|---|
| pfSense/네트워크 팀원 | PC3 연결 구조·주소, 실제 웹 진입점·HTTPS, 강제 경유·우회 차단, 노드/DB 통신 보존 |
| 인프라/DB 담당 | 최신 복제·예약 백업 상태 확인, 앱 전용 DB 계정, Kubernetes DB 전환·백업 역할 변경 설계 |
| 웹 담당 | 새 HTTPS 주소의 로그인·Origin·쿠키·업무 API, Pod 교차 세션과 장애 중 요청 결과 |
| 관제/자동화 담당 | 대시보드·GELF·n8n의 새 경로, 원래 클라이언트 IP·이벤트/티켓 중복·토큰 연결 재검증 |

## 참고

- [Kubernetes ConfigMap: 환경변수·subPath 갱신 조건](https://kubernetes.io/docs/concepts/configuration/configmap/)
- [kubectl port-forward의 Pod 선택·종료 동작](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_port-forward/)
- [pfSense 인터페이스와 브리지 구분](https://docs.netgate.com/pfsense/en/latest/bridges/index.html)
