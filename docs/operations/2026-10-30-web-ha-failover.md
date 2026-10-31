# 10월 30일 웹 재배포와 PC1 VM 자동 전환 시험

기록 대상은 2026-10-30 현장 작업이다. 사용자가 제공한 실행 결과와 화면을 근거로 작성했으며 작성자가 현장 서버에 직접 접속한 결과는 아니다. 이전 기록은 [10월 29일 현장 기록](2026-10-29-web-ha-replication.md)을 참고한다.

## 마감 상태

| 항목 | 확인한 결과 | 남은 확인 |
| --- | --- | --- |
| 웹·API 재배포 | 양쪽 노드에 API·Web 배치, 직접 HTTPS와 공개 HTTPS 응답 성공 | 재부팅 후 실제 설정과 로그인·쓰기 재확인 |
| 노드 내부 경로 | 공개 edge가 같은 노드의 API·Web 전용 Service를 사용하도록 변경 | 저장소 배포 정의에 반영하여 재배포 시 유지 |
| HAProxy | API readiness를 HTTPS로 검사, 장애 감지와 재분배 설정 적용 | 장시간 관찰 및 장애 중 로그인·쓰기 시험 |
| 최종 자동 전환 시험 | PC1 Ubuntu VM 중단 시 PC1 DOWN, PC2 UP. API 112건·웹 112건 모두 HTTP 200 / curl 0 | 종료·재시작 시각을 포함한 전환 시간 측정 |
| PC1 VM 재기동 | 두 노드 Ready, API·Web 2/2 확인 | 재기동 직후 admin-edge·automation-edge·public-edge는 1/2였으므로 최종 2/2 재확인 |
| DB·백업 | PC2 Primary 유지, Primary 예약 백업 시험 성공 | PC1 복제의 최신 상태, 별도 장비 백업 사본 |

**공개 웹의 PC1 VM 장애 대응 시험은 관찰한 224건에서 실패가 없었다. 물리 PC1 전체 장애, 제어부 고가용성, 모든 연결의 무중단과 장애 중 쓰기까지 완료했다는 의미는 아니다.**

## 재배포와 환경 설정

- DB 스키마 변경 없이 웹·API를 재배포했다. 두 노드의 API와 Web 정상 배치 및 HTTPS 응답을 확인했다.
- 호스트의 `.env` 파일은 이미지 교체만으로 Pod에 자동 반영되지 않는다. Ubuntu 프로젝트 루트와 `backend`의 파일을 읽어 API용 Secret 파일로 전달하는 절차를 사용했다. 중복 키는 backend 파일을 우선한다.
- `/app/.env` 파일을 마운트하고 API Pod를 교체하는 방식이며 이미지에 비밀 파일을 넣는 방식은 아니다. 파일만 수정한 뒤에는 해당 반영 절차와 API 검증을 다시 수행해야 한다.
- 반영 절차에서는 실행 중인 DB 연결 설정과 기존 내부 API 토큰 등 보호 대상 설정을 유지했다. 단순히 과거 로컬 `.env`의 PC1 DB/root 설정을 운영에 덮어쓰지 않는다.
- 공개 기준 주소는 `https://192.168.3.30`이다. 관제 도구 URL이나 키가 설정되었다는 사실만으로 n8n·Grafana·Zabbix 연동 성공을 판단하지 않는다.
- 실제 `.env`, Secret 원본, 토큰, 비밀번호, 개인키 및 pfSense 설정 백업은 이 기록에 포함하지 않는다.

## 같은 노드의 API·Web을 사용하는 공개 경로

namespace는 `telecom`이다. 기존 Service의 내부 Cluster 정책을 일괄 변경하지 않고 별도 Service를 추가했다.

| Service | 종류 | internalTrafficPolicy | 포트 / targetPort | selector |
| --- | --- | --- | --- | --- |
| telecom-api-local | ClusterIP | Local | 5000 / 5000 | app=telecom-api |
| telecom-web-local | ClusterIP | Local | 80 / 80 | app=telecom-web |

공개 `telecom-edge-config`의 두 upstream만 다음과 같이 바꿨다.

```nginx
location /api/ {
    proxy_pass http://telecom-api-local:5000;
}
location / {
    proxy_pass http://telecom-web-local:80;
}
```

위 코드는 변경한 upstream 설명이며 전체 설정을 대체할 파일이 아니다. `/api/internal` 차단, 인증 전달 헤더와 TLS 설정은 유지했다. admin-edge와 automation-edge는 이번 공개 upstream 변경 대상이 아니다.

- 기존 ConfigMap·Deployment 및 복구 패치를 개인 작업 폴더에 보관하고 두 edge Pod에서 `nginx -t` 성공을 확인했다.
- 공개 edge의 순차 교체는 `maxSurge: 0`, `maxUnavailable: 1`로 진행했다. rollout 성공 후 두 Pod의 `nginx -T`에서 새 upstream을 확인했다.
- 양쪽 edge에서 같은 노드 API의 readiness와 Web 연결 성공을 확인했다. 양쪽 NodePort 30443 직접 접근과 공개 443도 정상 응답했다.
- 공개 edge의 `externalTrafficPolicy: Local`을 유지한다. 기존 API·Web Service의 `internalTrafficPolicy: Cluster`도 유지한다.
- EndpointSlice에 두 노드 주소가 표시되는 것만으로 Local 정책 실패라고 판단하지 않는다. 각 노드의 실제 접속 시험을 함께 확인한다.
- Local 경로에는 해당 노드의 준비된 API·Web Pod가 필요하다. 한 노드에 해당 Pod가 없으면 그 노드의 공개 경로는 실패할 수 있다.

## HAProxy 최종 확인 설정

PC3 pfSense의 `telecom-public-nodes_ipvANY` Backend에 적용한 값이다. 관리 화면에서 저장·적용했으며 생성된 `haproxy.cfg`를 직접 수정하지 않는다.

| 항목 | 값 |
| --- | --- |
| 공개 진입 | 192.168.3.30:443, TCP / TLS 통과 |
| 서버 | pc1-web 192.168.7.185:30443 / pc2-web 192.168.7.100:30443 |
| 분산 | roundrobin, 두 서버 active |
| 검사 | HTTPS GET /api/health/ready, HTTP/1.0 |
| TLS | check-ssl 및 프로젝트 웹 CA 사용, 서비스 전달용 Encrypt(SSL)은 끔 |
| Connection timeout | 1000 ms |
| Server timeout | 30000 ms |
| Retries | 1 |
| Check frequency | 1000 ms |
| Per server pass thru | fall 2 rise 2 |
| Backend pass thru | option redispatch 1 / timeout check 2s, 각각 별도 줄 |
| 검사 로그 | Log checks 활성화 |

적용 후 두 서버의 `UP / L7OK 200` 및 공개 readiness 200을 확인했다. 이전 `/edge-health`는 edge 자체 확인이었고 새 `/api/health/ready` 검사는 API의 DB 연결까지 포함한다. 정적 Web은 별도로 `/` 요청으로 확인했다. 이미 생성된 TLS 연결을 다른 서버로 이동시키는 기능은 아니다.

## 시험 결과와 해석

| 단계 | 관찰한 결과 | 해석 |
| --- | --- | --- |
| 기존 내부 Cluster 경로에서 PC1 VM 중단 | API 120건 중 95건 성공, 25건 실패: curl 28 1건·502 2건·504 22건 | PC2 edge에서 API ClusterIP 연결 거부·시간 초과 로그 확인 |
| Local upstream 적용 후, HAProxy 조정 전 | API 14건·웹 15건 성공, 시간 초과 3건 | 전환 구간의 실패가 남아 추가 조정 |
| PC1 MAINT, PC2 경로 비교 | HAProxy API·웹 각 10건, PC2 직접 API·웹 각 10건 모두 성공 | 수동으로 PC1을 제외한 경로 점검 |
| PC1 MAINT 후 VM 중단 | 같은 네 가지 조합 40건 모두 성공 | PC2 서비스의 PC1 VM 의존성 분리 확인. 자동 감지 시험과 구분 |
| 최종 자동 전환 | API 112건, 웹 112건 모두 HTTP 200·curl 0, 실패 목록 없음 | PC1이 자동 DOWN인 화면과 PC2 UP 확인. 224건 관찰 범위의 성공 |

최종 화면에서 112회씩 확인한 결과만 기록한다. 계획한 최대 반복 횟수 전체 실행이나 정확한 장애 지속 시간·전환 시간은 확인하지 않았다. 앞선 실패 결과도 개선 전 기록으로 보존한다.

시험 중 관리 계정 잠금은 다른 작업자의 로그인 시험 때문이라고 사용자가 확인했다. readiness·웹 조회 시험을 잠금의 원인으로 단정하지 않는다.

## 현재 한계와 다음 작업

1. PC1 재기동 후 모든 Deployment 2/2, CoreDNS 양쪽 1/1, HAProxy 두 서버 UP을 확인한다.
2. PC2 DB의 Primary 역할과 두 API의 실제 DB 대상을 확인하고 PC1 `pc2_to_pc1` 복제 IO/SQL·TLS·지연을 재확인한다. 이전 PC1→PC2 채널을 시작하지 않는다.
3. 관제 담당자와 테스트 시간을 맞춘 뒤 장애 중 기존 로그인 유지, 조회와 구분 가능한 시험 데이터 쓰기·재조회·PC1 복제를 확인한다. 중복 결제나 실제 운영 데이터 변경은 시험 대상으로 삼지 않는다.
4. 공개 edge의 Local 경로, CoreDNS 분산, HAProxy 설정을 저장소 배포 정의와 대조해 재배포 후 되돌아가지 않도록 정리한다.
5. PC2 n8n 전용 10443의 실제 인증 이벤트 전달과 일반 PC 차단을 담당자와 검증한다. 현재 이 입구는 PC1 VM 30445 고정 NAT이며 공개 443의 자동 분산과 같은 구성이 아니다.
6. PC1 Graylog가 없어도 PC2 Wazuh·n8n·Zabbix에서 경보가 이어지는지 별도 검증한다. Wazuh 전달 도구의 pending 기록이 있었으므로 최종 해소 여부도 확인한다.
7. Primary 예약 백업·Discord 감시와 PC1 Replica 백업, PC2 외부 백업 사본을 점검한다.

PC1은 유일한 k3s control plane이다. PC1 VM 중단 중 기존 PC2 Pod가 응답한 결과는 새 Pod 생성·재배치·설정 변경이 가능한 제어부 고가용성을 뜻하지 않는다. PC3 pfSense도 단일 진입점이다. PC1 물리 장비 전체 종료 시험은 별도 범위와 복구 절차를 준비한 뒤 진행한다.

종료와 다음 시작 순서는 [운영 종료·재시작 절차](../runbooks/telecom-planned-shutdown-startup.md)를 따른다.
