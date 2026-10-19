# B 기반 검증 기록

검증일: 2026-10-19 / Windows 개인 개발 PC / Docker Desktop 4.49.0, Engine 28.5.1, Compose 2.40.3-desktop.1. 공용 PC를 대상으로 실행하지 않았습니다.

| 검사 | 결과 | 범위·증거 |
|---|---|---|
| Docker Engine 응답 | PASS | Server.Version 28.5.1 |
| 로컬 TLS 인증서 | PASS | 생성된 CA로 인증서·IP SAN 검증, 시스템 신뢰 설정 변경 없음 |
| HTTP → HTTPS | PASS | 실제 로컬 Nginx 설정에서 308·8443 Location 확인 |
| SPA 직접 경로 | PASS | 임시 화면 서버의 /dashboard 응답 |
| API 프록시·헤더 | PASS | 임시 API 5000 전달, 위조 X-Forwarded-For/Proto/Request-ID 덮어쓰기 |
| 외부 관리·내부 API 차단 | PASS | 정확한 경로·하위 경로·인코딩·중복 슬래시·상위 경로 정규화 9개가 404 |
| 새 볼륨 GTID 초기화 | PASS | telecom-b-db-lab-clean에서 별도 Primary/Replica 생성, 기존 실습 데이터 보존 |
| 복제·쓰기 거절 | PASS | B-DB-REPLICATION, 합성 UUID 행 일치·GTID 적용·read_only/super_read_only=1·앱 쓰기 ERROR 1290 |
| 복제 스레드 | PASS | receiver/applier ON, worker 오류 번호 0 |
| 분리 복원 | PASS | B-DB-RESTORE, 별도 mysql-restore의 telecom_restore_test에 합성 1행 복원·비교 |
| PC1/PC2 Nginx 문법 | PASS | 각 렌더링 파일을 nginx 1.28.3 컨테이너에서 nginx -t |
| Bash 문법 | PASS | backup.sh, restore-test.sh, check-edge.sh, collect-host-inventory.sh 각 bash -n |
| Compose·Python·렌더링 | PASS | local/db-lab config --quiet, Python 도구 5개 AST, kubectl kustomize |
| 비밀값 제외 | PASS | .env, .secrets/tls/ca.key, .data/db-lab-backups의 git check-ignore 확인 |
| 앱 전체 이미지·로그인·CSRF | 미검증 | A의 package.json/lock, requirements.txt, wsgi.py 없음 |
| 운영 GPG 백업·키 복구·외부 매체 | 미검증 | 스크립트 문법만 검증, 실제 암호화·복원 실행 필요 |
| k3s API 서버 검증·스케줄링 | 미검증 | kustomize 렌더링만 확인, 실제 노드·이미지·Secret 없음 |
| Keepalived 문법·VRRP·VIP 이동 | 미검증 | Linux 장비·실제 NIC·동일 L2 준비 후 확인 |
| 실제 VLAN·방화벽·NetworkPolicy | 미검증 | C의 장비·정책 준비 후 공동 시험 |
| 공용 PC MySQL·수동 승격 | 미검증 | 실행 구성·호스트 fencing·검증 TLS·실제 GTID 확인 필요 |
| 관제·자동화·티켓·알림 | 미검증 | A/D 코드 및 서비스 통합 필요 |

## 재현 명령

저장소 루트에서 실행합니다. 비밀값이 출력되는 전체 Compose config 또는 원본 DB 로그는 검증 증거로 올리지 않습니다.

```powershell
python infrastructure/tools/proxy-smoke.py
python infrastructure/tools/mysql-lab.py init --project telecom-b-db-lab-review1
python infrastructure/tools/mysql-lab.py verify --project telecom-b-db-lab-review1
python infrastructure/tools/mysql-lab.py restore-test --project telecom-b-db-lab-review1
python infrastructure/tools/mysql-lab.py status --project telecom-b-db-lab-review1
python infrastructure/tools/mysql-lab.py down --project telecom-b-db-lab-review1
docker compose --env-file .env -f infrastructure/docker/compose/local/compose.yaml --profile app --profile ops config --quiet
kubectl kustomize infrastructure/kubernetes/base
```

DB 실습 TLS는 서버 신원 미검증입니다. 합성 로컬 덤프는 `.data/`에서 Git 제외되며 운영 데이터 백업으로 사용하지 않습니다. 프록시 테스트는 자신이 생성한 임시 컨테이너·네트워크만 정리합니다. DB 실습 종료는 볼륨을 보존합니다.

## Docker Desktop 오류 복구 기록

증상은 Inference manager 시작 중 `dockerInference` 소켓 제거 실패였습니다. Docker 프로세스가 종료된 상태를 확인하고 런타임 소켓 폴더만 recovery 이름으로 보존한 뒤 재시작하여 Engine 응답을 확인했습니다. factory reset·이미지/볼륨 삭제는 하지 않았습니다. 이 복구를 다른 Docker 오류의 공통 해결법으로 사용하지 않습니다.
