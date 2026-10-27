# MySQL 접근 제한과 웹 앱 계정 분리

상태: **현장 점검 결과 확인 / 변경 안내 단계**, 2026-10-27. 사용자 요청에 따라 앱 전용 계정 이름은 `webuser`로 정한다. 계정 생성·앱 전환 완료 출력은 아직 없다. 관리자 웹 접근을 허용해도 사용자 PC에 MySQL 3306을 개방하지 않는다. [관리자 웹 전환](academy-admin-access.md)과 DB 접근 제한은 별도 단계로 검증한다.

## 10월 27일 추가 점검 결과

| 관측 | 판단 |
|---|---|
| PC1·PC2 Domain Enabled True, Private/Public False | Private/Public 프로필 방화벽 꺼짐. 현재 NIC 프로필 출력은 미제공이므로 함께 확인 필요 |
| 일반 PC `.3.21` → `.3.18:3306`, `.3.19:3306` TCP True | 양쪽 DB 포트에 일반 사용자 PC가 도달 가능. DB 인증 성공을 의미하지는 않음 |
| PC1 Windows 관측 원본 `.7.185`, `.7.100`, `.3.19` | 현재 API·PC2 연결의 허용 대상 후보를 실제 관측. 프로그램·프로필·규칙까지 확인 후 제한 |
| 두 API USER() `root@172.17.0.1`, CURRENT_USER() `root@%` | 웹 앱에 DB 관리자 계정 사용 중. MySQL은 Docker NAT 뒤의 공통 원본을 인식 |
| 두 API session `Ssl_cipher` 빈 값 | 시험한 앱 DB 연결은 암호화되지 않음. 웹 HTTPS·복제 TLS와 별개 |
| 양쪽 `0.0.0.0:3306` 및 `127.0.0.1:3306` listener, PID 다름 | PID/실행 프로그램 추가 확인 대상. 이 목록만으로 MySQL 서버가 두 개라고 단정하지 않음 |

앱 계정 분리는 필요한 개선이지만 DB 포트 노출과 미암호화까지 해결하지는 않는다. 계정 시험 → 앱 연결 전환 → 원본별 방화벽 제한 → DB TLS를 각각 검증한다. 현장 유효 방화벽 규칙 목록이 아직 없어 특정 기존 규칙의 일괄 변경을 안내하지 않는다.

## webuser 생성과 사전 연결 시험

PC1 Windows에서 Primary 관리자 계정으로 접속한다.

```powershell
docker exec -it flask_mysql mysql --user=root --password
```

기존 계정 충돌을 확인한다.

```sql
SELECT User, Host FROM mysql.user WHERE User = 'webuser';
SELECT @@partial_revokes AS partial_revokes;
```

기존 webuser가 있으면 이 생성 절차를 중단하고 해당 계정의 용도·권한을 먼저 확인한다. 없으면:

```sql
CREATE USER 'webuser'@'172.17.0.1' IDENTIFIED BY RANDOM PASSWORD;
```

생성된 암호는 현장에서 비공개로 보관하고 채팅·Git·스크린샷에 넣지 않는다. MySQL이 실제 인식한 원본 `172.17.0.1`만 허용한다. 이는 Windows 방화벽용 허용 IP가 아니며 Docker 환경 변경 시 다시 확인한다. 일반 사용자도 Docker를 통해 이 원본으로 보일 수 있으므로 계정 HOST 제한이 네트워크 차단을 대체하지 않는다.

`partial_revokes=0`이면 DB 이름의 밑줄 와일드카드를 이스케이프해 다음 권한을 부여한다.

```sql
GRANT SELECT, INSERT, UPDATE, DELETE
ON `my\_new\_board\_db`.* TO 'webuser'@'172.17.0.1';
```

`partial_revokes=1`이면 밑줄이 이미 문자로 처리되므로 위 GRANT 대신 아래를 사용한다. 두 가지를 모두 실행하지 않는다.

```sql
GRANT SELECT, INSERT, UPDATE, DELETE
ON `my_new_board_db`.* TO 'webuser'@'172.17.0.1';
```

확인:

```sql
SHOW GRANTS FOR 'webuser'@'172.17.0.1';
exit;
```

USAGE ON *.*는 별도 관리자 권한 부여가 아니다. 실제 업무 DB CRUD 외 CREATE/DROP/ALTER, GRANT OPTION, 전역 관리 권한이 없어야 한다. 이 단계는 기존 앱 계정을 바꾸지 않는다. 현재 앱이 TLS를 쓰지 않으므로 여기서 REQUIRE SSL이나 전역 require_secure_transport를 먼저 켜지 않는다.

PC1 Ubuntu에서 다음을 실행한다. 각 Pod에서 새 암호를 숨김 입력하고 접속만 시험한다. 기존 API 프로세스·자격증명은 변경하지 않는다.

```bash
pods="$(sudo k3s kubectl -n telecom get pods -l app=telecom-api -o name)"
for pod in $pods; do
  echo "검사: $pod"
  sudo k3s kubectl -n telecom exec -it "$pod" -c api -- python -c '
from getpass import getpass
from pathlib import Path
from sqlalchemy import create_engine, text
from sqlalchemy.engine import make_url
from wsgi import app
url = make_url(app.config["SQLALCHEMY_DATABASE_URI"]).set(username="webuser", password=getpass("webuser password: "))
engine = create_engine(url, pool_pre_ping=True)
with engine.connect() as conn:
    print(tuple(conn.execute(text("SELECT CURRENT_USER(), DATABASE(), 1")).one()))
print("/app/.env exists:", Path("/app/.env").is_file())
engine.dispose()
'
  result=$?
  if [ "$result" -ne 0 ]; then
    echo "중단: webuser 접속 시험 실패"
    break
  fi
done
```

두 Pod에서 `webuser@172.17.0.1`, `my_new_board_db`, `1`이 출력되면 접속 시험 성공이다. 암호 오입력으로 예외가 나오면 예외에 연결 URL/암호가 없는지 확인 후 공유한다. `/app/.env`가 존재하면 현재 소스가 환경변수를 덮어쓸 수 있으므로 파일 공급 위치를 먼저 확인한다. 존재하지 않으면 API 전용 Secret과 DB_USER/DB_PASSWORD 명시적 secretKeyRef를 사용하는 다음 전환 절차를 준비할 수 있다. 기존 공유 Secret을 무조건 수정하지 않는다.

## 확인된 설계와 주의점

- PC1 Windows `.3.18`의 `flask_mysql`: API와 PC2 Replica가 접근해야 한다.
- PC2 Windows `.3.19`의 `mysql-lab`: 기존 백업 도구는 `docker exec`와 컨테이너 내부 `protocol=SOCKET`을 사용한다. 이 백업을 위해 학원 사용자에게 PC2 3306을 열 필요가 없다.
- 기존 배포 도구는 두 DB 모두 `0.0.0.0:3306:3306` 게시를 전제로 한다. 현재 운영 포트는 현장에서 확인한다. 이 바인딩만으로 방화벽이 실제 허용하는지 판단하지 않는다.
- PC2 복제는 PC2에서 PC1로 연결한다. 정상 응답을 받기 위해 PC2의 외부 3306 인바운드를 추가 개방하는 구조가 아니다.
- Windows가 관측하는 원본 주소와 MySQL이 관측하는 HOST는 Docker Desktop·k3s NAT로 다를 수 있다. 두 관측을 구분한다.
- 기존 root 앱 사용은 과거 화면에서 확인됐으며 현재 실행 Pod를 다시 조회한다. 기존 `loop_app` 계정은 다른 전환 도구가 사용하므로 임의로 비밀번호·권한을 재설정하지 않는다.
- **자료 없이 3306 전체 차단, 전체 방화벽 초기화, root 계정 삭제, DB 컨테이너 재생성을 하지 않는다.**

## 1. PC1·PC2 Windows: 읽기 전용 네트워크 점검

각 PC의 관리자 PowerShell에서 실행한다. 이 단계는 설정을 변경하지 않는다.

```powershell
Get-NetConnectionProfile | Select-Object InterfaceAlias,NetworkCategory
Get-NetFirewallProfile -PolicyStore ActiveStore | Select-Object Name,Enabled,DefaultInboundAction,DefaultOutboundAction
Get-NetTCPConnection -LocalPort 3306 -ErrorAction SilentlyContinue | Select-Object LocalAddress,LocalPort,RemoteAddress,RemotePort,State,OwningProcess
```

PC1:

```powershell
docker port flask_mysql
```

PC2:

```powershell
docker port mysql-lab
```

API 접속을 유지하고 복제 스레드가 Yes인 상태에서 관측한다. 출력에 API·복제 연결이 안 잡히면 짧은 연결일 수 있으므로 요청 직후 다시 확인한다. 연결 목록 한 번으로 모든 허용 대상을 확정하지 않는다.

다음은 TCP 3306·포트 범위·Any 포트에 영향을 줄 수 있는 활성 인바운드 규칙을 조회한다. 실제 매칭은 주소·프로그램·서비스·프로필을 함께 판단한다. RPC 등 특수 포트 토큰은 자동 분류하지 않는다.

```powershell
$loopDbRules = foreach ($rule in Get-NetFirewallRule -PolicyStore ActiveStore -Enabled True -Direction Inbound) {
    $ports = @($rule | Get-NetFirewallPortFilter)
    $loopPortMatches = $false
    foreach ($port in $ports) {
        if ([string]$port.Protocol -notin @('TCP','6','Any','256')) { continue }
        foreach ($token in @($port.LocalPort)) {
            if ([string]$token -in @('Any','3306')) { $loopPortMatches = $true }
            elseif ([string]$token -match '^(\d+)-(\d+)$') {
                if ([int]$Matches[1] -le 3306 -and [int]$Matches[2] -ge 3306) { $loopPortMatches = $true }
            }
        }
    }
    if ($loopPortMatches) {
        $address = $rule | Get-NetFirewallAddressFilter
        $application = $rule | Get-NetFirewallApplicationFilter
        $service = $rule | Get-NetFirewallServiceFilter
        [pscustomobject]@{
            Name = $rule.Name
            DisplayName = $rule.DisplayName
            Action = $rule.Action
            Profile = $rule.Profile
            LocalPort = ($ports.LocalPort -join ',')
            LocalAddress = ($address.LocalAddress -join ',')
            RemoteAddress = ($address.RemoteAddress -join ',')
            Program = $application.Program
            Service = $service.Service
            PolicySourceType = $rule.PolicyStoreSourceType
        }
    }
}
$loopDbRules | Format-List
```

Docker 전체 프로그램에 대한 Any 허용이 있으면 좁은 포트 허용 규칙을 하나 추가하는 것만으로 접근 제한이 되지 않는다. 다만 Docker 프로그램 규칙을 일괄 비활성화하면 Wazuh·Graylog 등 다른 서비스에 영향을 줄 수 있다.

## 2. PC1 Ubuntu: 실제 API 계정·DB 관측 원본 확인

두 API Pod가 준비된 상태에서 실행한다. 암호·세션·Secret 전체를 출력하지 않는다.

```bash
bash <<'BASH'
set -euo pipefail
pods="$(sudo k3s kubectl -n telecom get pods -l app=telecom-api -o name)"
test -n "$pods"
for pod in $pods; do
  echo "검사: $pod"
  sudo k3s kubectl -n telecom exec -i "$pod" -c api -- python - <<'PY'
from sqlalchemy import text
from wsgi import app
from app.extensions import db
with app.app_context():
    with db.engine.connect() as conn:
        row = conn.execute(text('SELECT USER() AS connection_identity, CURRENT_USER() AS authenticated_account, DATABASE() AS database_name')).mappings().one()
        print(dict(row))
        print('session_tls:', tuple(conn.execute(text("SHOW SESSION STATUS LIKE 'Ssl_cipher'")).one()))
PY
done
BASH
```

`USER()`의 host는 MySQL이 인식한 접속 주소이고 Windows 방화벽용 원본 IP와 같다는 보장은 없다. session_tls가 비어 있으면 해당 앱 DB 연결의 TLS가 확인되지 않은 것이다. 복제가 TLS라고 앱 DB 연결까지 암호화됐다고 판단하지 않는다.

PC1 Windows에서 기존 관리자 인증으로 계정·접속 목록도 확인한다.

```powershell
docker exec -it flask_mysql mysql --user=root --password
```

`mysql>`에서:

```sql
SELECT User, Host, account_locked FROM mysql.user
WHERE User IN ('root','loop_app','webuser','loop_repl','loop_backup');
SELECT USER, HOST, COMMAND FROM information_schema.PROCESSLIST
WHERE USER NOT IN ('event_scheduler','system user');
```

`authentication_string`이나 전체 SQL 실행 내용을 조회·공유하지 않는다. 기존 앱 계정과 이름이 겹치는지, 복제 사용자가 어떤 HOST로 보이는지 확인한다.

## 3. 별도 사용자 PC: 현재 노출 범위 확인

PC1·PC2·PC3가 아닌 학원망 PC에서 실행한다.

```powershell
Test-NetConnection 192.168.3.18 -Port 3306
Test-NetConnection 192.168.3.19 -Port 3306
```

현재 True여도 DB 인증 성공을 의미하지 않는다. 최종 목표는 두 직접 연결 False, 웹 HTTPS 443 True다. 시험 PC의 IP도 기록하되 필요한 학원 대역 밖을 스캔하지 않는다.

## 4. 점검 결과를 받은 후 적용할 순서

이 절은 실행 계획이다. 아직 원본 IP·유효 규칙을 받지 않았으므로 임의 주소를 넣은 변경 명령은 제공하지 않는다.

1. PC1·PC2 방화벽 정책을 현장 비공개 파일로 백업하고, 변경할 규칙 Name·주소·포트·프로그램·활성 상태를 별도 저장한다. 다른 서비스의 규칙을 구분한다.
2. PC1 DB에는 실제 관측된 API·Replica·승인된 DB 운영 출발지만 허용하도록 설계한다. `.7.185/.7.100/.3.19`는 후보일 뿐 NAT 후 실제 관측으로 확정한다. 승인 관리 PC라는 이유로 PC1~3 모두에 무조건 3306을 허용하지 않는다.
3. 기본 인바운드 차단과 좁은 허용 규칙을 조합하고 기존 광범위 DB/프로그램 허용을 정리한다. **명시적인 3306 전체 Block 뒤에 Allow를 추가하는 방식은 쓰지 않는다.** Windows는 일반적으로 명시적 Block이 Allow보다 우선한다. 공유 Docker 규칙을 줄여야 한다면 다른 서비스에 필요한 허용을 먼저 준비한다. 정책이 GPO로 관리되면 로컬 규칙으로 해결됐다고 가정하지 않는다.
4. 한 PC씩 적용하고 즉시 두 API readiness, Replica IO/SQL Yes, 고객 조회, 관리자 조회, 백업 시험을 확인한다. 문제가 생기면 새로 만든 규칙과 수정한 기존 규칙만 복원한다. 방화벽 전체 비활성화를 복구 방법으로 사용하지 않는다.
5. 앱 전용 새 계정 `webuser`를 위 절차로 관측된 DB host 범위에 만든다. 업무 DB의 SELECT/INSERT/UPDATE/DELETE부터 부여하고 필요한 추가 권한은 실제 사용으로 검증한다. CREATE/DROP/ALTER, GRANT OPTION, CREATE USER, FILE, 전역 관리 권한은 런타임 계정에 주지 않는다. schema migration은 별도 운영 계정으로 수행한다.
6. 계정 암호는 현장에서 생성·입력하고 Git·명령행 인수·채팅·공개 로그에 넣지 않는다. 기존 root·loop_repl·loop_backup·loop_app 암호를 변경하지 않는다. Primary의 계정 생성이 필터된 Replica에 자동 복제된다고 가정하지 않고 장애 전환용 계정 준비를 별도로 확인한다.
7. 실제 Deployment의 DB_USER/DB_PASSWORD 공급 위치를 확인한다. Secret 일부 키만 바꾸더라도 같은 Secret을 사용하는 migration Job 등에 영향이 있을 수 있다. 앱 전용 Secret으로 분리하는 안을 우선 검토한다. 환경변수보다 `/app/.env`가 우선하는 소스가 있으므로 배포된 이미지에서 실제 연결 계정이 바뀌었는지 다시 조회한다. Secret 값을 화면에 출력하지 않는다.
8. 기존 자격증명 참조를 비공개로 보존하고 API를 순차 재시작한다. 두 Pod CURRENT_USER가 새 계정인지, 읽기·쓰기·세션·관리자 작업이 정상인지 확인한다. 실패 시 API의 기존 자격증명 참조를 복원하고 재시작한다. 기존 root 계정 제거는 별도 검토 후 수행한다.
9. 다른 학원 PC에서는 3306 연결 실패, 443 웹 접속 성공, CUSTOMER 관리자 API 403, ADMIN 관리자 API 200을 검증한다. 보안 시험은 시험 계정·시험 데이터로만 수행한다.

DB 전용 계정 전환·방화벽 축소·관리자 웹 개방을 한 번에 적용하지 않는다. 계정 전환과 DB 접근 제한을 각각 검증한 후 관리자 공개 경로를 전환하면 장애 원인을 구분하기 쉽다.

## 완료 판단

- [ ] 실제 Windows 원본 주소와 MySQL 접속 HOST를 구분해 기록.
- [ ] 사용자 PC의 PC1·PC2 3306 직접 연결 차단, 필요한 API·복제·백업 유지.
- [ ] API의 최소 권한 계정 전환 및 DDL/전역 관리 권한 없음 확인.
- [ ] Secret 적용·계정·방화벽별 롤백 가능, 기존 업무 회귀 성공.
- [ ] 재부팅 후 정책 유지와 추가 사용자 PC 시험.

근거: [OWASP Database Security](https://cheatsheetseries.owasp.org/cheatsheets/Database_Security_Cheat_Sheet.html), [Microsoft 방화벽 규칙 우선순위](https://learn.microsoft.com/en-us/windows/security/operating-system-security/network-security/windows-firewall/rules), [Docker Desktop 네트워크](https://docs.docker.com/desktop/features/networking/).
