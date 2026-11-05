# 두 노드의 웹/API 클린 릴리스

현장: PC1 Ubuntu `pc1-k3s / 192.168.7.185`, PC2 Ubuntu `pc2-k3s / 192.168.7.100`, namespace `telecom`. 현재 DB는 PC2 Windows Primary `192.168.3.19 / my_new_board_db / webuser`를 유지한다. 공개 고객 주소는 `https://192.168.3.30`, 관리 전용 주소는 `https://192.168.7.178:9443/admin`이다.

2026-11-04부터 **공개 관리자 UI/API 404가 정상 정책**이다. ADMIN 권한 검사는 관리 전용 입구에서도 유지한다. 공개 관리자 404를 배포 오류로 취급하거나 차단을 제거하는 이전 릴리스 도구를 사용하지 않는다. [공개 관리자 차단 절차](academy-admin-access.md)를 먼저 확인한다.

## 모드와 사전 조건

| 목적 | PC1 Ubuntu 명령 | 처리 |
|---|---|---|
| 이미지 변경 | `apply-images` | 기존 env/envFrom/Secret 참조·마운트 보존, env 파일 읽기·새 Secret 생성 없음 |
| 이미지와 Flask 환경 파일 변경 | `apply` | Ubuntu 루트 `.env`와 `backend/.env`를 읽어 새 immutable Secret 사용. 중복 항목은 backend 파일 우선 |
| 이미 시작한 릴리스 검사 | `verify` | 재적용 없이 이미지·환경·접근 정책 확인 |

DB migration·역할 변경·계정 생성은 자동 실행하지 않는다. 새 DB 스키마가 필요한 릴리스는 별도 migration 계획을 마련한다. React `VITE_*`는 빌드 시점 값이다.

2026-11-05부터 `telecom-edge-proxytest`가 있으면 PROXY용 Service의 Local/포트/selector와 ConfigMap·두 실행 Pod의 출발지 신뢰/차단 정책도 검사한다. 준비 도구가 `loop-client-ip-test.py`를 함께 전달한다. 기존 `telecom-edge` 검사도 유지하며 pfSense의 실제 연결 대상은 [실제 IP 전달 절차](academy-client-ip-preservation.md)에 따라 현장에서 확인한다.

시작 전 PR이 main에 병합됐는지 확인한다. 두 노드와 API/Web/공개 Edge는 각각 두 Pod Ready, 노드별 한 Pod여야 한다. 관리 Edge도 Ready여야 한다. 공개 관리자 차단과 관리 전용 로그인·조회를 먼저 확인한다. `.env`, 토큰, 원시 백업·릴리스 상태를 Git이나 채팅에 올리지 않는다.

## PC1 Windows: 도구 받기와 빌드·전송

Docker Desktop의 Linux 컨테이너, Git, SSH/SCP 및 VM 인증이 필요하다. PR 병합 후 PowerShell:

```powershell
& {
    $ErrorActionPreference = 'Stop'
    $loopTools = Join-Path $env:USERPROFILE ('Downloads\telecom-release-tools-' + (Get-Date -Format 'yyyyMMddHHmmss'))
    git clone --no-checkout --filter=blob:none --branch main --single-branch https://github.com/telecom-carrier-Loop/telecom-security-project.git $loopTools
    if ($LASTEXITCODE -ne 0) { throw '도구 저장소 복제 실패' }
    git -C $loopTools sparse-checkout set --no-cone '/infrastructure/tools/webapi-release/'
    if ($LASTEXITCODE -ne 0) { throw '도구 경로 선택 실패' }
    git -C $loopTools checkout --detach origin/main
    if ($LASTEXITCODE -ne 0) { throw '도구 체크아웃 실패' }
    $loopPrepare = Join-Path $loopTools 'infrastructure\tools\webapi-release\prepare-images.ps1'
    Unblock-File -LiteralPath $loopPrepare
    powershell -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File $loopPrepare
    if ($LASTEXITCODE -ne 0) { throw '빌드 또는 전송 실패. 다음 단계로 진행하지 마세요.' }
}
```

준비 도구는 기존 프로젝트와 별도의 `telecom-clean-source-날짜`/`telecom-clean-release-날짜` 폴더를 만든다. 최신 origin/main의 고정 커밋을 clean detached checkout으로 사용하며 이미지와 검증 스크립트 모두 그 커밋에서 가져온다. backend/frontend와 Dockerfile, `release.py`, 독립형 정책 검사 `k3s-admin-access.py`를 선택한다.

이미지에는 전체 소스 커밋 라벨·고유 태그를 붙이고 env 파일 제외를 검사한다. TAR·체크섬/이미지 메타데이터·두 Python 도구를 **두 VM에 모두** 전송한다. `.telecom-clean-release` 포인터가 새 디렉터리를 가리킨다. 출력의 COMMIT과 TAG를 기록한다. 정책 도구가 누락된 수동 패키지는 다시 생성한다.

## 양쪽 Ubuntu: 각각 이미지 등록

PC1과 PC2에서 각각 실행한다.

```bash
loopRelease="$(cat "$HOME/.telecom-clean-release")"
sudo -v && python3 "$loopRelease/release.py" import
```

archive SHA256 및 backend/frontend config digest·태그·소스 커밋 PASS를 확인한다. OCI index/manifest ID를 단순 문자열 비교하지 않고 archive의 linux/amd64 config digest까지 검사한다. 등록만 재확인하려면 `check-import`를 사용한다.

도구는 반대 VM의 등록 결과를 자동 보증하지 않는다. 작업자가 **두 VM의 동일 COMMIT/TAG와 PASS를 확인한 후** 진행한다.

## PC1 Ubuntu: 적용

환경 변경이 없는 기본 모드:

```bash
loopRelease="$(cat "$HOME/.telecom-clean-release")"
sudo -v && python3 "$loopRelease/release.py" apply-images
```

API/Web 이미지와 소스 커밋 annotation을 교체하며 기존 환경 참조·마운트·affinity를 보존한다. `imagePullPolicy: Never`, `maxSurge: 0`, `maxUnavailable: 1`을 사용한다. API의 유효 DB·보호된 토큰 설정이 바뀌면 검사를 중단한다.

Flask 환경 파일도 반영할 때만 위 명령 **대신** 실행한다.

```bash
sudo -v && python3 "$loopRelease/release.py" apply
```

이 모드는 `/home/loop/telecom-security-project/.env`와 `backend/.env`를 읽는다. DB 접속 항목, APP_ENV, INCIDENT/AUTOMATION 토큰은 현재 앱 설정을 보존하고 `TRUSTED_PROXY_HOPS=1`, `PUBLIC_BASE_URL=https://192.168.3.30`을 사용한다. 다른 항목은 파일에서 가져온다. 기존 명시 env·`/app/.env` 마운트의 우선순위와 유효 Flask 설정을 검사한다.

배포 전후에 공개 ConfigMap과 **두 공개 Edge의 실제 `nginx -T`**에서 관리자 차단 네 개, 내부 API 차단, 고객 upstream을 확인한다. 부분 차단·알 수 없는 구문·다른 위치에 있는 차단을 정상으로 간주하지 않는다. 관리 Edge Ready 및 두 API의 ADMIN 역할 래퍼·미인증 401도 검사한다. 해당 검사는 읽기 전용이며 공개·관리 Edge 정책을 덮어쓰지 않는다.

## PC1 Ubuntu: 배포 결과

```bash
sudo -v && python3 "$loopRelease/release.py" verify
sudo k3s kubectl -n telecom get pods -l 'app in (telecom-api,telecom-web,telecom-edge)' -o wide
```

SOURCE_COMMIT은 Windows의 COMMIT과 같아야 한다. API/Web/공개 Edge는 노드별 한 Pod가 Ready여야 한다. 이미지 전용 모드는 `ENV_SETTINGS_PRESERVED=True`, 환경 반영 모드는 `ENV_MATCH=True`를 확인한다.

## Windows와 외부 PC의 회귀 시험

프로젝트 CA를 신뢰하는 Windows에서 새 요청:

```powershell
curl.exe --noproxy "*" --ssl-revoke-best-effort --connect-timeout 3 --max-time 10 -sS -i "https://192.168.3.30/api/health/ready"
curl.exe --noproxy "*" --ssl-revoke-best-effort --connect-timeout 3 --max-time 10 -sS -o NUL -w "HTTP=%{http_code}\n" "https://192.168.3.30/admin"
curl.exe --noproxy "*" --ssl-revoke-best-effort --connect-timeout 3 --max-time 10 -sS -o NUL -w "HTTP=%{http_code}\n" "https://192.168.3.30/api/admin/dashboard"
curl.exe --noproxy "*" --ssl-revoke-best-effort --connect-timeout 3 --max-time 10 -sS -o NUL -w "HTTP=%{http_code}\n" "https://192.168.3.30/api/internal/privilege-violations"
```

readiness는 200/database ok, 공개 관리자와 내부 API는 404다. 공개 고객 로그인·업무, 허용 PC에서 사설 관리자 로그인·조회·새로고침, 비허용 PC 새 연결 차단, 실제 VPN, HAProxy 두 서버 UP, 관제·자동화 및 직접 NodePort 우회 검사를 별도로 기록한다. 사설 주소의 HTTP 200만으로 로그인·권한·PC 제한 성공을 표시하지 않는다.

## 중단과 복구

STOP이면 두 VM을 켠 채 첫 오류와 현재 Pod 상태를 점검한다. 이미 시작한 릴리스에서 `apply`/`apply-images`를 반복하지 말고 `verify`를 사용한다. 백업이나 상태 파일을 임의로 지우지 않는다.

PC1 Ubuntu에서 필요 시:

```bash
loopRelease="$(cat "$HOME/.telecom-clean-release")"
sudo -v && python3 "$loopRelease/release.py" rollback
```

동시 배포가 없을 때 기록된 이전 API/Web 템플릿만 복원한다. DB·Ubuntu env 파일·공개 Edge ConfigMap을 되돌리지 않는다. Secret과 백업은 보존한다. `deployment-state.json`은 보호된 설정을 포함할 수 있으므로 공개하지 않는다. 공개 Edge 정책 복구는 별도의 [관리자 차단 도구](academy-admin-access.md)를 따른다.

## 로컬 검사

```bash
python -m unittest discover -s infrastructure/tools/tests -p test_k3s_admin_access.py -q
python -m unittest discover -s infrastructure/tools/webapi-release -p test_release.py -q
```

릴리스 도구는 Python 표준 라이브러리를 사용한다. 기존 환경 직렬화 테스트에는 `python-dotenv`가 필요하다. 로컬·모의 클러스터 검사를 운영 이중화 재배포나 VPN/실제 PC 시험 완료로 표시하지 않는다.
