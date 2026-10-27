# 학원망 이중화 현황과 단계별 시험

2026-10-27 저장소 설정·현장 화면·사용자 보고 기준. 이 문서는 점검 결과와 시험 절차이며 장애 주입이나 실제 PC/VM 종료를 수행한 기록이 아니다.

## 현재 판정

**Web/API의 양 노드 실행은 확인됐으나 PC1 물리 서버 전체 장애를 PC2가 자동으로 대신하는 서비스 전체 HA는 미완성이다.** 분산 배치, 요청 분산, 장애 시 진입점 전환, DB 승격, 제어부 가용성을 각각 판정한다.

| 계층 | 현재 근거 | 판정·빠진 부분 |
|---|---|---|
| Web/API Pod | 각각2개, PC1/PC2 분산 배치. 템플릿은 hostname 기준 required anti-affinity | 실행본 복제는 있음. 실제 요청이 양쪽에 도달하는 로그 시험은 별도 |
| 내부 Service | 현재 API ClusterIP:5000, web ClusterIP/NodePort30080. 앞단 Nginx가 Service 이름으로 전달 | Ready endpoint로 분산하는 구조. 실측50:50이나 세션·업무 전체 성공까지 보장하지 않음 |
| 공개 HTTPS 진입 | .3.30:443 → .7.185:30443 | PC1에 고정된 NAT 대상. 장애 감지 후 .7.100으로 자동 전환하는 앞단 구성은 확인되지 않음 |
| 자동화10443 진입 | PC2 → .3.30:10443 → .7.185:30445 | 프록시는 양 노드에 있지만 pfSense의 대상은 PC1 고정. 향후 전환 시 PC2 원본 제한과 SNAT/Local 정책도 유지해야 함 |
| 기존 관리자9443 | 승인된 PC3 → .7.185:30444 | 별도 경로도 PC1 의존. 공개443의 ADMIN 세션 접근과 구분 |
| DB | PC1 Windows Primary, PC2 Replica. 앱은 .3.18을 사용 | GTID 복제·백업은 있음. 자동 승격·쓰기 주체 격리·새 대상 선택은 없음 |
| 승격 후 PC2 DB 접근 | 현재 PC2 3306은 로컬 원본만 허용 | 승격 시 API VM의 접근 허용·앱 계정/권한·TLS·대상 변경 절차를 별도 검증해야 함 |
| 승격 후 백업 | mysql84-backup.ps1은 replica-ready/IO·SQL ON/read_only=1 등을 검사 | PC2 Primary 승격 뒤 기존 백업이 그대로 동작한다고 가정하면 안 됨. 역할별 백업/감시 정책 필요 |
| k3s 제어부 | PC1만 Server/control plane, PC2는 Agent | PC1 전체 장애 시 kubectl 설정 갱신·새 스케줄링·rollout과 장애 endpoint 갱신을 정상 수행할 수 없음. 남은 Pod 동작은 별도 실측 |
| pfSense | PC3의 단일 VM | PC3/pfSense 장애 시 현재 공통 서비스 주소도 단일 장애점 |
| DNS·세션 | API 세션 정본은 MySQL. Nginx는 Service 이름 사용 | CoreDNS 배치/노드 간 통신과 DB가 함께 살아야 함. 남은 Pod의 단순 Running만으로 웹 정상 판정 불가 |

`infrastructure/keepalived/*.conf.example`에는 REPLACE_WITH_VLAN10_INTERFACE와 과거192.168.10.x가 남아 있다. 이 파일이 있다는 이유로 현재 학원망에 VIP 자동 전환이 설치됐다고 판단하지 않는다. `infrastructure/kubernetes/base`도 옛 VLAN/NodePort 예제이며 현재 현장에 전체 apply하지 않는다.

## 장애 범위별 예상

| 장애 | 기대 가능한 범위와 한계 |
|---|---|
| API Pod1개 종료 | 제어부·DB·다른 endpoint가 정상이라면 남은 API로 처리하고 Deployment가 대체Pod를 생성할 수 있음. 일시 실패와 실제 회복 시간 측정 필요 |
| PC2 Ubuntu VM 장애 | PC1 제어부·DB·진입점은 남음. PC2 실행본은 사라지며 required anti-affinity 때문에 PC1에2개를 강제로 보충하지 않음 |
| PC1 Ubuntu VM만 장애 | Windows DB는 남을 수 있으나 NAT 대상과 유일한 제어부를 잃음. 현재 공통 URL의 자동 복구를 기대하지 않음 |
| PC1 Windows MySQL만 장애 | API 두 개 모두 같은 DB에 의존해 readiness 실패 가능. PC2 Replica 자동 승격은 없음 |
| PC1 물리PC 전체 장애 | 제어부·NAT 대상·Primary·일부 관제 동시 중단. PC2에Pod가 남아도 서비스 전체 자동 승계를 뜻하지 않음 |

`systemctl stop k3s`만으로 모든 컨테이너가 종료되는 것은 아니므로 물리PC/VM 전체 장애 시험과 같게 취급하지 않는다. killall/uninstall이나 VM 강제종료를 가벼운 점검 명령으로 사용하지 않는다.

## 1. 먼저 읽기 전용 상태 확인 — PC1 Ubuntu

```bash
sudo k3s kubectl get nodes -o wide
sudo k3s kubectl -n telecom get deployments
sudo k3s kubectl -n telecom get pods -o wide
sudo k3s kubectl -n telecom get services -o wide
sudo k3s kubectl -n telecom get endpointslices \
  -l kubernetes.io/service-name=telecom-api -o wide
sudo k3s kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide
```

확인 항목: 두 노드 Ready, Web/API/공개 edge 각각2개, API Ready endpoint2개, 실제 Service policy/port와 CoreDNS 배치. API Pod가 하나라도0/1이면 장애 시험 전에 원인을 해결한다. CoreDNS가 PC1에만 있다면 PC1 중단 후 이름 해석·신규 프록시 시작은 보장되지 않는 항목으로 기록한다.

## 2. 양쪽 노드의 HTTPS 개별 확인 — PC2 Windows PowerShell

기존 프로젝트 CA를 신뢰한 Windows에서 실행한다. 인증서 검증 대상 주소는 .3.30으로 유지하고 접속 대상만 각 NodePort로 바꾼다. pfSense를 우회한 내부 경로 시험이며 공개 진입점의 자동 전환 시험은 아니다.

```powershell
foreach ($loopHaNode in @('192.168.7.185', '192.168.7.100')) {
    Write-Host "HTTPS node: $loopHaNode"
    $loopHaConnect = '192.168.3.30:443:{0}:30443' -f $loopHaNode
    curl.exe --noproxy '*' --ssl-revoke-best-effort --connect-timeout 3 --max-time 10 --connect-to $loopHaConnect -sS -i 'https://192.168.3.30/api/health/ready'
}
```

양쪽 모두 HTTP200/database ok가 기대값이다. Timeout은 먼저 Windows→VM 경로/방화벽, 502/503은 API endpoint/DB, TLS 오류는 CA/SAN을 확인한다. 시험을 이유로 일반 사용자에게 DB/NodePort를 개방하지 않는다.

## 3. API 요청 분산을 로그로 확인

### PC2 Windows PowerShell

서비스를 중단하지 않고 공개 HTTPS로 DB readiness 읽기 요청30회를 보낸다. 여러 API Pod에 도달하는지 확인하는 시험이며 처리 성능을 측정하는 부하 시험은 아니다. 로그인·고객 정보·내부 자동화 API를 사용하지 않는다.

```powershell
$loopHaRun = 'ha-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
Write-Host "Run ID: $loopHaRun"
$loopHaResults = foreach ($loopHaIndex in 1..30) {
    $loopHaUrl = 'https://192.168.3.30/api/health/ready?ha_probe={0}&n={1}' -f $loopHaRun, $loopHaIndex
    $loopHaCode = & curl.exe --noproxy '*' --ssl-revoke-best-effort --connect-timeout 3 --max-time 8 -sS -o NUL -w '%{http_code}' $loopHaUrl
    $loopHaExit = $LASTEXITCODE
    [pscustomobject]@{ Request=$loopHaIndex; HTTP=$loopHaCode; CurlExit=$loopHaExit }
    Start-Sleep -Milliseconds 100
}
$loopHaResults | Format-Table -AutoSize
```

### PC1 Ubuntu

위에서 출력된 Run ID를 입력한다. 실제 Gunicorn access log에 query가 기록되는 구성을 전제로 해당 요청만 추린다.

```bash
read -r -p 'PC2에 표시된 Run ID: ' loopHaRun
sudo k3s kubectl -n telecom logs -l app=telecom-api -c api \
  --since=10m --tail=1000 --prefix=true --max-log-requests=10 | grep -F "$loopHaRun"
```

판정: PC2의30건이 HTTP200/CurlExit0이고 **서로 다른 API Pod2개**의 로그에 이 Run ID가 보여야 한다. 로그 prefix의 Pod 이름을 get pods -o wide의 NODE와 대응한다. 정확히15:15일 필요는 없다. 한쪽만 보이거나 로그가 없다면 미확인으로 남기고 selector/endpoint/실제 access log 설정/연결 재사용을 확인한다. 일반 프로브 요청을 이번 시험 요청으로 세지 않는다.

이 시험은 API Service의 요청 분산을 확인한다. 외부 edge와 정적 Web의 각 Pod가 절반씩 받았는지, PC1 장애 후 지속되는지, 세션·쓰기까지 정상인지는 별도 시험이다.

## 4. 중단 시험 전에 보완할 순서

1. 위의 상태·양 NodePort·API 분산을 측정한다. 현장 값·시각·성공/실패 수를 기록한다.
2. PC3에 양 노드를 대상으로 하는 상태 감시형 진입점(예: HAProxy)을 설계하고 별도로 적용한다. 공개443과 내부10443의 원본 Source 제한을 구분한다. TLS, SNAT, 반환 경로, 관리 GUI 포트, 인증 헤더 처리도 검증한다. NAT alias에 IP2개만 넣는 것으로 장애 노드가 자동 제외되지는 않는다.
3. 제어부 HA/복구 방침을 먼저 정한다. 현재 VM 추가는 PC1·PC2 안에서만 가능하므로 embedded etcd Server3개를 두 물리PC에 배치해도 양쪽 어느 물리PC의 장애든 견디는 quorum은 만들 수 없다. 독립 장애 영역을 추가하거나 대응 범위를 제한한 복구 계획이 필요하다.
4. DB는 쓰기 중단→구 Primary의 확실한 격리(fencing)→GTID/지연과 손실 범위 판단→검증된 Replica 승격→안정된 DB 진입점/앱 연결→기능 확인→구 Primary 재가입까지 준비한다. 양쪽 동시 쓰기를 만들지 않는다.
5. PC2 Primary일 때의 앱 계정, VM→PC2:3306 제한 허용, 백업/Discord 감시 역할 전환을 준비한다. 일반 PC에 DB를 개방하거나 Replica 보호 조건을 삭제하는 방식으로 해결하지 않는다.
6. 먼저 Pod1개 계획 중단·재생성, 다음 PC2 VM만, 마지막으로 독립 복구 수단을 준비한 PC1 VM/물리PC 시험 순서로 진행한다. 이 문서는 지금 즉시 중단하라는 지시가 아니다.

시험 기록: 장애 범위, 시작/복구 시각, HTTP 실패 수, 남은 Pod와 endpoint, 같은 URL의 접속 지속 여부, DB 쓰기 대상의 단일성, 데이터 차이, 로그인·읽기·합의된 쓰기, 감시 알림, 복구 후 역할/복제 상태. 기존 로그인 유지도 쿠키/DB 세션 의존성을 포함해 확인한다.

## 근거와 참조

- [Kubernetes Service](https://kubernetes.io/docs/reference/kubernetes-api/core/service-v1/): Local은 해당 노드의 endpoint만 사용한다. 외부 진입점의 노드 장애 전환을 자동 구현하지 않는다.
- [K3s embedded etcd HA](https://docs.k3s.io/datastore/ha-embedded): Server3대 이상과 quorum. 물리 배치에 대한 판단은 이 규칙을 현재 두 물리PC 제약에 적용한 것이다.
- [K3s Server/Agent](https://docs.k3s.io/architecture): Agent는 control plane이 없다.
- [pfSense Port Forward](https://docs.netgate.com/pfsense/en/latest/nat/port-forwards.html): 다중 목적지 alias만으로 중단된 대상을 제외하지 않으며 분산/전환에는 HAProxy를 안내한다.
- [K3s 중지](https://docs.k3s.io/upgrades/killall): 서비스 중지 후에도 컨테이너가 계속 실행될 수 있다.
- [현장 서비스 복구](../operations/2026-10-27-service-recovery.md), [MySQL/k3s 이전과 역할 전환](mysql84-k3s-impact.md), [최신 자동화 입구](../operations/2026-10-27-automation-ingress-handoff.md). 과거 VLAN/VIP 예제와 현재 구성을 구분한다.
