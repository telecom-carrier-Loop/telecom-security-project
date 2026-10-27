# 현장 보고서에 따른 MySQL 3306 접근 제한

2026-10-27. **PC1 재시도 후 연결·HTTPS 정상 사용자 보고 / PC2 적용 대기**. [계정 분리·네트워크 점검](mysql-network-access-hardening.md)의 후속이다. 두 API의 실제 계정 `webuser@172.17.0.1`과 공개 HTTPS readiness 200을 확인했다. 변경 후 관제 전체 회귀와 PC2는 [공유 이슈 #40](https://github.com/telecom-carrier-Loop/telecom-security-project/issues/40)에서 추적한다.

## 보고서에서 확인한 값

| 대상 | 첫 번째 보고서: PC1 | 두 번째 보고서: PC2 |
|---|---|---|
| Windows 주소 | 192.168.3.18 | 192.168.3.19 |
| 이더넷 프로필 | Public | Public |
| 방화벽 | Domain True, Private/Public False | 동일 |
| DB | flask_mysql, 0.0.0.0:3306 | mysql-lab, 0.0.0.0:3306 |
| Docker TCP 규칙 | com.docker.backend.exe / Public / Any 포트·원본 허용 | Docker Desktop Backend / Public / Any 포트·원본 허용 |
| 기타 | PC2→PC1 3306 전용 허용 규칙도 존재 | 외부 DB 접속 필요성 미확인, 백업은 컨테이너 내부 소켓 |

각 보고서의 Docker 프로그램 규칙 Name·경로를 도구에 명시했다. Windows 앱 패키지 규칙은 Program Any로 출력돼도 패키지 조건이 있을 수 있어 일괄 비활성화하지 않는다.

PC1 Docker 게시 서비스: API 5000, Grafana 3000, Graylog TCP 9000/12201·UDP 1514/5140/12201, Wazuh Dashboard 443·Manager TCP 1514/1515, n8n 5678. PC2: API 5000, Zabbix 웹 8081·서버 10051, Wazuh Dashboard 443·Manager TCP 1514/1515, n8n 5678. 게시되지 않은 Indexer·Mongo·OpenSearch·Postgres 포트는 추가 개방하지 않는다.

## 변경 정책

도구: `infrastructure/tools/mysql-firewall-scope.ps1`. Windows 관리자 PowerShell 전용이다.

1. 실제 호스트 IP·Public 프로필·기본 Block/Allow 정책·기존 Docker TCP 규칙 필터·3306 소유 프로세스를 검사한다. 다른 프로그램이 3306을 열고 있거나 보고서와 다르면 변경 전에 중단한다.
2. 전체 방화벽 정책 before.wfw와 원래 Public 활성 상태, 변경 규칙 이름을 다운로드 폴더에 저장한다.
3. 원래 Docker 프로그램·Public 프로필의 TCP 허용을 `1-3305,3307-65535`로 나눈 대체 규칙을 생성한다. **이것은 다른 Docker TCP 포트의 기존 노출을 유지하는 과도기 설정이며 전체 서비스 최소 권한 구성 완료가 아니다.**
4. PC1의 Docker TCP 3306은 `127.0.0.1`, `.3.18`, `.3.19`, `.7.185`, `.7.100`에 허용한다. PC2는 로컬 `127.0.0.1`, `.3.19`만 허용한다. Windows가 규칙 원본으로 거부한 IPv6 루프백 `::1`은 포함하지 않는다. 앱이 인식한 `172.17.0.1`을 Windows 원본 허용 목록으로 사용하지 않는다.
5. PC1 Graylog UDP 1514/5140/12201은 학원 실습 대역 `.3.0/24`, `.7.0/24`에서 허용한다. 이미 더 넓은 UDP 규칙이 있다면 이 추가 규칙만으로 범위가 좁아진 것은 아니다. 네이티브 TCP 10050 listener가 있으면 Zabbix 서버 후보 PC1·PC2 주소의 접속을 준비한다.
6. 확인된 기존 Docker TCP Any 규칙만 비활성화하고 **현재 사용 중인 Public 프로필만** 활성화한다. Domain·Private는 변경하지 않는다. Private는 여전히 꺼져 있으므로 다른 프로필까지 완료됐다고 기록하지 않는다.
7. 적용 실패 시 도구가 만든 규칙과 원래 Docker 규칙·Public 활성 상태를 복원한다. 성공 후 네트워크 회귀 시험이 실패하면 Rollback을 사용한다. 이전 Public이 꺼져 있었다면 복구 시 그 상태로 돌아가므로 문제 해결 후 제한 정책을 다시 준비해야 한다.

원본 출발지·미래 DB 장애 전환 계정·DB TLS·5000 직접 API·관리 UI 노출 축소는 후속 과제다. 보고서에 별도 Docker `telecom-api` 5000이 두 PC에서 실행 중이며, k3s API의 webuser 전환이 이 별도 컨테이너까지 변경한 것은 아니다. 사용 의존성을 확인한 뒤 별도 계정 점검·중지·접근 제한을 검토한다. 이 도구는 pfSense·k3s·DB 계정·컨테이너 바인딩을 바꾸지 않는다.

## 1. PC1 Windows: 도구 받기

관리자 PowerShell에서 실행한다. git pull이나 기존 수정 파일 초기화 없이 원격 도구만 추출한다.

```powershell
Set-Location "$env:USERPROFILE\telecom-security-project"
git fetch origin
if ($LASTEXITCODE -ne 0) { throw 'Git fetch 실패' }
$loopFirewallTool = Join-Path $env:USERPROFILE 'Downloads\mysql-firewall-scope.ps1'
$loopFirewallSource = git show origin/codex/mysql-firewall-scope-20261027:infrastructure/tools/mysql-firewall-scope.ps1
if ($LASTEXITCODE -ne 0) { throw '도구 가져오기 실패' }
$loopFirewallSource | Set-Content -LiteralPath $loopFirewallTool -Encoding utf8
```

## 2. PC1 계획 확인과 적용

```powershell
powershell -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File "$loopFirewallTool" -Role PC1 -Action Plan
```

Plan은 설정을 바꾸지 않는다. `Wrong host`, `unexpected process`, `rule has changed` 등으로 중단되면 원본 조건을 지우지 말고 결과를 확인한다. PC1의 MySQL 허용 원본에 `.7.185/.7.100/.3.19`가 포함되고 Docker NonDB 규칙에서 3306이 제외되는지 확인한다.

```powershell
powershell -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File "$loopFirewallTool" -Role PC1 -Action Apply
```

정상 메시지: `Applied. Verify new external connections...`. 동일 Apply를 반복하지 않는다.

```powershell
powershell -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File "$loopFirewallTool" -Role PC1 -Action Status
```

Public True, 새 규칙 Enabled True 확인. 이 결과만으로 사용자 DB 차단이나 전체 관제 성공을 확정하지 않는다.

## 3. PC1 적용 직후 필수 시험

PC2 Windows의 새 TCP 연결은 성공해야 한다.

```powershell
Test-NetConnection 192.168.3.18 -Port 3306
```

별도 사용자 PC(예: `.3.21`)의 새 DB 연결은 실패하고 공개 HTTPS는 정상이어야 한다.

```powershell
Test-NetConnection 192.168.3.18 -Port 3306
curl.exe --noproxy "*" --ssl-revoke-best-effort --connect-timeout 3 --max-time 8 -sS -i "https://192.168.3.30/api/health/ready"
```

PC1 Ubuntu에서 두 Pod 각각 새로운 DB 연결을 만든다. 기존 연결이 살아 있는 것만으로 방화벽 허용을 판정하지 않는다.

```bash
pods="$(sudo k3s kubectl -n telecom get pods -l app=telecom-api -o name)"
for pod in $pods; do
  echo "$pod"
  sudo k3s kubectl -n telecom exec -i "$pod" -c api -- python - <<'PY'
from sqlalchemy import text
from wsgi import app
from app.extensions import db
with app.app_context():
    with db.engine.connect() as conn:
        print(tuple(conn.execute(text('SELECT CURRENT_USER(), DATABASE(), 1')).one()))
PY
  if [ "$?" -ne 0 ]; then break; fi
done
```

두 번 모두 webuser / 업무 DB / 1 확인. 고객 조회·기존 관리자 9443, Graylog의 새 로그 도착, Wazuh agent 최근 접속, Grafana·n8n 접근, 실제 알림 파이프라인을 확인한다. 기존 Docker TCP 범위는 유지하지만 네이티브 Windows 서비스나 별도 방화벽 정책은 회귀 시험이 필요하다. 실패 시 PC2에 적용하지 않고 PC1부터 복구한다.

## 4. PC2는 PC1 시험 성공 후 적용

PC2 관리자 PowerShell에서 단계 1의 도구 받기를 반복하고 아래를 실행한다.

```powershell
powershell -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File "$loopFirewallTool" -Role PC2 -Action Plan
powershell -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File "$loopFirewallTool" -Role PC2 -Action Apply
powershell -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File "$loopFirewallTool" -Role PC2 -Action Status
```

실제 실행은 각 명령이 성공한 뒤 다음 명령으로 진행한다. 사용자 PC에서 `.3.19:3306` 새 연결 False, PC2 내부 백업 Test 성공, Replica IO/SQL Yes와 오류 없음, Zabbix 최근 데이터·Wazuh·n8n 및 Discord 파이프라인 정상 확인. PC2 백업 도구가 컨테이너 내부 소켓을 사용하더라도 실제 새 백업으로 확인한다.

## 5. 문제 발생 시 해당 PC만 롤백

PC1:

```powershell
powershell -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File "$loopFirewallTool" -Role PC1 -Action Rollback
```

PC2:

```powershell
powershell -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File "$loopFirewallTool" -Role PC2 -Action Rollback
```

원래 규칙을 삭제하지 않으므로 정확한 이름으로 다시 활성화한다. 다른 기존 방화벽 규칙은 삭제하지 않는다. 이전 프로필 상태로 되돌린 뒤 장애 원인을 점검한다. before.wfw 전체 import는 다른 사람의 후속 변경까지 덮어쓸 수 있어 자동으로 실행하지 않는다. 도구는 롤백 소유권·역할·로컬 IP를 검사하고 상태 파일이 있으면 Apply 재실행을 거절한다.

## 현장 첫 적용 실패와 복구 후 재시도

초기 PC1 Apply에서 `New-NetFirewallRule`이 RemoteAddress의 `::1`을 거부했다. 자동 복구도 `System.Boolean False`를 NetSecurity의 `GpoBoolean`으로 변환하지 못해 중단됐다. 도구 오류이며 계정·DB 오류가 아니다. 코드 순서상 첫 NonDB 규칙이 남았을 수 있고, 기존 Docker 규칙과 Public 프로필의 최종 상태는 Status로 확인해야 한다.

수정본은 `::1`을 제거하고, 프로필 활성 상태를 enum 이름 문자열 `'True'`/`'False'`로 전달한다. 실패 당시 state.json과 before.wfw를 지우지 않는다.

1. 위 단계 1로 도구를 다시 가져온다.
2. PC1에서 수정본 `-Role PC1 -Action Rollback`을 실행한다. 정상 메시지는 `Restored the previous Public profile state and the original Docker rule.`이다.
3. 기본 상태 디렉터리의 Status에서 `rolled-back`을 확인한다. 복구는 이전 Public 비활성 상태로 돌아갈 수 있다. 여기서 또 오류가 나면 새 Apply를 실행하지 않는다.
4. 이전 상태 파일을 보존하고 새 디렉터리에서 재시도한다.

```powershell
$loopFirewallRetry = Join-Path $env:USERPROFILE ('Downloads\telecom-db-scope-PC1-retry-' + (Get-Date -Format yyyyMMdd-HHmmss))
powershell -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File "$loopFirewallTool" -Role PC1 -Action Plan -StateDirectory "$loopFirewallRetry"
```

Plan 성공 후:

```powershell
powershell -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File "$loopFirewallTool" -Role PC1 -Action Apply -StateDirectory "$loopFirewallRetry"
```

Apply 성공 후:

```powershell
powershell -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File "$loopFirewallTool" -Role PC1 -Action Status -StateDirectory "$loopFirewallRetry"
```

이 재시도의 복구도 같은 `-StateDirectory "$loopFirewallRetry"`를 지정한다. PC2에는 수정본을 내려받고, PC1의 연결·관제 검증이 끝난 뒤 적용한다.

## 검증 범위

- PowerShell 문법 및 모의 방화벽 시험으로 Plan 무변경, 잘못된 호스트·프로필·listener·규칙 변경 거부, PC1 원본 보존, PC2 로컬 제한, 관제 허용 준비, 부분 실패 복구를 검사했다.
- 초기 모의 시험은 실제 API의 IPv6 loopback 거부와 GpoBoolean 바인딩 차이를 잡지 못했다. 수정 회귀 시험은 이 두 조건을 거부하는 모의 cmdlet과 중단된 이전 state의 복구→새 디렉터리 재시도를 포함한다. 실제 NetSecurity Enabled 매개변수 타입에 대한 문자열 변환도 읽기 전용으로 확인한다.
- 모의 시험은 실제 방화벽을 바꾸지 않았다. 현장 네트워크·Docker Desktop·GPO 효과는 위 외부 연결 시험으로 확인해야 한다.
- PC1 수정본 재시도 후 연결·HTTPS 시험 정상 사용자 보고가 있다. 개별 Status·TCP 결과 증거 보강, 두 API 새 연결과 관제 회귀, PC2 적용·전체 검증·재부팅 검증은 남아 있다.

근거: [Microsoft 방화벽 규칙](https://learn.microsoft.com/en-us/windows/security/operating-system-security/network-security/windows-firewall/rules), [Docker Desktop 포트 게시와 방화벽](https://docs.docker.com/desktop/features/networking/).
