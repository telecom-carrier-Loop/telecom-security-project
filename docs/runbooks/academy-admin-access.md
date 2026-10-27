# 학원망 공통 HTTPS 주소의 ADMIN 권한 기반 접근 전환

상태: **실행 안내 / 현장 적용 전**. 2026-10-27 사용자 요청에 따라 PC1·PC2·PC3 이외의 학원망 PC를 프로젝트 외부 사용자로 정의한다. 인터넷 공개나 VLAN 분리는 아니다.

## 목표와 변경 범위

- 같은 `https://192.168.3.30`에서 CUSTOMER는 고객 기능, ADMIN은 관리자 기능을 사용한다.
- 관리자 여부는 pfSense나 브라우저가 아니라 Flask의 서버 세션·사용자 역할로 판단한다. 9443 자동 리디렉션을 추가하지 않는다.
- pfSense의 기존 `.3.0/24 → .3.30:443 → .7.185:30443`과 반환 SNAT를 유지한다. 다른 대역 사용자는 별도 라우팅 검토 대상이다.
- 공개 `telecom-edge-config`의 관리자 경로 404 블록만 제거한다. `/api/internal` 차단, TLS, proxy 헤더, 기존 9443·관리 GUI·SSH·DB 접근 정책은 유지한다.
- k3s public edge 변경은 그 edge로 연결된 기존 8443/직접 NodePort에도 적용된다. `.3.30`에만 한정된 변경이 아니다. 서버 RBAC는 모든 해당 경로에서 동작해야 한다.

## 1. 저장소 코드 검토와 현장 사전 검사

사용자 요청에 따라 [DB 네트워크 접근 제한·앱 계정 분리](mysql-network-access-hardening.md)를 별도로 진행한다. 관리자 웹 허용을 위해 3306을 사용자에게 개방하지 않는다. DB 변경과 공개 관리자 전환은 각각 검증하며 한 번에 적용하지 않는다.

기준 소스 `69fff4c`의 `backend/app` AST 검사에서 `/api/admin` 아래 route 선언 42개에 모두 `@roles_required(ROLE_ADMIN)`이 있었다. `core/permissions.py`는 미로그인 401, 역할 불일치 403, 변경 요청 CSRF 검사를 수행한다. `core/sessions.py`는 매 요청 DB 세션과 사용자 활성·잠금 상태를 확인한다. `frontend/src/components/common/RequireAuth.tsx`는 화면 진입 제어를 담당한다.

정적 검사이며 현장 실행 이미지와 같다고 단정할 수 없다. 로컬 Python에는 Flask/pytest 의존성이 없어 테스트 스위트는 실행하지 않았다. 기존 PC3 9443에서 CUSTOMER 거부·ADMIN 성공을 먼저 확인하고 아래로 **실행 중인 두 API 이미지**를 검사한다.

PC1 Ubuntu:

```bash
sudo k3s kubectl get nodes -o wide
sudo k3s kubectl -n telecom get pods -o wide
```

두 노드 Ready, API·edge 준비 상태 정상일 때 다음 블록을 실행한다. DB에 쓰지 않고 별도 Python 프로세스에서 등록된 핸들러의 권한 래퍼를 검사한다. 사용자 세션/비밀번호는 출력하지 않는다.

```bash
bash <<'BASH'
set -euo pipefail
pods="$(sudo k3s kubectl -n telecom get pods -l app=telecom-api -o name)"
test -n "$pods"
for pod in $pods; do
  echo "검사: $pod"
  sudo k3s kubectl -n telecom exec -i "$pod" -c api -- python - <<'PY'
import inspect
from wsgi import app
bad = []
count = 0
for rule in app.url_map.iter_rules():
    if not (rule.rule == '/api/admin' or rule.rule.startswith('/api/admin/')):
        continue
    count += 1
    fn = app.view_functions[rule.endpoint]
    protected = False
    while fn is not None:
        if (getattr(fn, '__code__', None)
                and fn.__code__.co_name == 'wrapper'
                and fn.__code__.co_filename.endswith('/core/permissions.py')):
            values = inspect.getclosurevars(fn).nonlocals
            if values.get('roles') == ('ADMIN',):
                protected = True
        fn = getattr(fn, '__wrapped__', None)
    if not protected:
        bad.append(rule.rule)
print('admin routes:', count, 'missing role wrapper:', bad)
if not count or bad:
    raise SystemExit('중단: 실행 이미지의 관리자 보호를 확인해야 합니다.')
PY
done
BASH
```

검사 성공도 전체 보안 검증은 아니다. 단계 5의 실제 401/403/200 시험이 필수다. 실행 이미지에서 래퍼 구조가 다르거나 실패하면 공개 차단을 제거하지 않고 소스·이미지부터 확인한다.

## 2. PC1 Ubuntu: 설정 백업과 수정본 추출

이후 명령은 같은 Ubuntu 셸에서 진행한다. 실행 전 전체 노드가 Ready이고 기존 공개/관리 경로가 정상이어야 한다.

```bash
loopAdminDir="$HOME/telecom-admin-access-$(date +%Y%m%d-%H%M%S)"
mkdir -m 700 "$loopAdminDir"
sudo k3s kubectl -n telecom get configmap telecom-edge-config -o json > "$loopAdminDir/before.json"
sudo k3s kubectl -n telecom get deployment telecom-edge -o yaml > "$loopAdminDir/deployment-before.yaml"
python3 - "$loopAdminDir" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
obj = json.loads((p/'before.json').read_text())
text = obj['data']['nginx.conf']
(p/'nginx-before.conf').write_text(text)
(p/'nginx-candidate.conf').write_text(text)
PY
echo "$loopAdminDir"
nano "$loopAdminDir/nginx-candidate.conf"
```

아래와 같은 **관리 페이지·관리 API 전용 return 404 블록만 삭제**한다.

```nginx
location = /admin { return 404; }
location ^~ /admin/ { return 404; }
location = /api/admin { return 404; }
location ^~ /api/admin/ { return 404; }
```

현장에 `location ~ ^/api/admin/` 등 정규식으로 같은 차단을 추가했다면 그 관리자 차단도 확인한다. 다른 설정 형태라면 자동 치환하지 말고 차이를 검토한다.

아래 내부 자동화 API 차단은 그대로 남겨야 한다.

```nginx
location = /api/internal { return 404; }
location ^~ /api/internal/ { return 404; }
```

기존 `/api/`는 `http://telecom-api:5000`, `/`는 `http://telecom-web:80`으로 프록시하는 상태를 유지한다. `/admin`은 기존 `/`에서 React로, `/api/admin/...`은 기존 `/api/`에서 Flask로 전달된다. 별도 DB 연결 설정은 추가하지 않는다.

nano 저장: Ctrl+O, Enter, Ctrl+X. 변경 확인:

```bash
diff -u "$loopAdminDir/nginx-before.conf" "$loopAdminDir/nginx-candidate.conf"
```

diff 종료 코드 1은 차이가 있다는 뜻이다. 관리자 차단 외에 TLS·internal 차단·헤더·upstream 변경이 보이면 진행하지 않는다.

## 3. 실행 중 edge와 같은 환경에서 문법 검사

기존 설정 파일을 덮어쓰지 않고 `/tmp`에 수정본을 전달해 검사한다. `edge` 컨테이너 이름이 다르면 먼저 실제 Deployment를 확인한다.

```bash
(
set -e
pods="$(sudo k3s kubectl -n telecom get pods -l app=telecom-edge -o name)"
test -n "$pods"
for pod in $pods; do
  sudo k3s kubectl -n telecom exec -i "$pod" -c edge -- sh -c 'cat > /tmp/telecom-admin-candidate.conf' < "$loopAdminDir/nginx-candidate.conf"
  sudo k3s kubectl -n telecom exec "$pod" -c edge -- nginx -t -c /tmp/telecom-admin-candidate.conf
done
)
```

모든 검사에서 `syntax is ok`, `test is successful`을 확인해야 다음으로 진행한다. 이 명령은 실제 Nginx reload를 하지 않는다.

## 4. ConfigMap의 nginx.conf만 변경하고 public edge 재시작

```bash
python3 - "$loopAdminDir" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
before = json.loads((p/'before.json').read_text())
patch = {'metadata': {'resourceVersion': before['metadata']['resourceVersion']},
         'data': {'nginx.conf': (p/'nginx-candidate.conf').read_text()}}
(p/'patch.json').write_text(json.dumps(patch))
PY
```

```bash
sudo k3s kubectl -n telecom patch configmap telecom-edge-config --type=merge --patch-file "$loopAdminDir/patch.json"
```

성공한 경우에만 다음 실행. Conflict면 다른 사람이 설정을 변경한 것이므로 새 원본과 비교해야 한다. resourceVersion을 지워 강제로 덮어쓰지 않는다.

```bash
sudo k3s kubectl -n telecom rollout restart deployment/telecom-edge
sudo k3s kubectl -n telecom rollout status deployment/telecom-edge --timeout=180s
```

ConfigMap이 바뀌어도 subPath 마운트는 자동 갱신되지 않으며 Nginx도 설정 재읽기가 필요하다. 따라서 public edge Pod를 순차 재생성한다. DB·API·web 이미지·관리 edge 재배포는 필요 없다.

## 5. PC1·PC2·PC3 이외 학원 PC에서 권한 시험

프로젝트 CA 공개 인증서를 신뢰 저장소에 등록한 Windows 계정으로 시험한다. 외부 사용자 PC에서 admin 계정까지 허용하는 정책이며 관리자 비밀번호 노출 면적은 기존 PC3 한정 정책보다 넓어진다.

```powershell
curl.exe --noproxy "*" --ssl-revoke-best-effort --connect-timeout 3 --max-time 8 -sS -i "https://192.168.3.30/api/health/ready"
curl.exe --noproxy "*" --ssl-revoke-best-effort --connect-timeout 3 --max-time 8 -sS -i "https://192.168.3.30/api/admin/dashboard"
curl.exe --noproxy "*" --ssl-revoke-best-effort --connect-timeout 3 --max-time 8 -sS -i "https://192.168.3.30/api/internal/probe"
```

각각 200(DB ok), 401(JSON), 404(edge 차단)가 기대값이다. `/api/internal/probe` 404 하나만으로 차단을 증명할 수 없으므로 적용된 `nginx -T`의 internal location 블록도 함께 확인한다.

브라우저에서 일반 CUSTOMER로 로그인하고 같은 출처의 콘솔에서 읽기 요청만 시험한다. 비밀 쿠키를 복사하지 않는다.

```javascript
fetch('/api/admin/dashboard', {credentials: 'same-origin'})
  .then(async r => console.log(r.status, await r.json()))
```

CUSTOMER는 403이어야 한다. 로그아웃 후 ADMIN으로 다시 로그인하면 같은 요청이 200, `/admin`의 업무 조회가 정상이어야 한다. 고객에게 관리자 데이터가 보이면 즉시 단계 6으로 되돌린다.

CSRF 확인은 ADMIN 세션에서 **읽기 전용 시험을 마친 뒤**, 운영 데이터를 수정하지 않는 로그아웃 요청으로 수행할 수 있다.

```javascript
fetch('/api/auth/logout', {method: 'POST', credentials: 'same-origin'})
  .then(async r => console.log(r.status, await r.json()))
```

CSRF 헤더가 없으므로 403 / CSRF_FAILED가 기대값이다. UI 로그아웃은 정상 성공해야 한다. 이전 9443 경로의 쿠키와 새 `.3.30` 쿠키는 다른 IP이므로 `.3.30`에서 다시 로그인한다.

운영 계정의 역할을 시험 목적으로 변경하지 않는다. 권한 회수 검증은 별도 시험 ADMIN 계정으로 역할 회수 후 기존 세션 요청이 403인지 확인한다. 앱 감사 로그에서 실제 사용자 ID별 기록을 확인한다.

## 6. 롤백

원래 Ubuntu 셸의 `loopAdminDir`를 사용한다. 변수가 없어졌다면 단계 2에서 출력한 정확한 폴더를 지정한다. 다른 작업자가 ConfigMap을 수정했다면 원본을 덮어쓰기 전에 변경을 조정한다.

```bash
python3 - "$loopAdminDir" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
before = json.loads((p/'before.json').read_text())
(p/'rollback.json').write_text(json.dumps({'data': {'nginx.conf': before['data']['nginx.conf']}}))
PY
sudo k3s kubectl -n telecom patch configmap telecom-edge-config --type=merge --patch-file "$loopAdminDir/rollback.json"
```

patch 성공 후:

```bash
sudo k3s kubectl -n telecom rollout restart deployment/telecom-edge
sudo k3s kubectl -n telecom rollout status deployment/telecom-edge --timeout=180s
```

**rollout undo만으로는 변경한 ConfigMap 내용이 복구되지 않는다.** 공개 admin 404 복구, 일반 readiness 200, 기존 PC3 관리자 9443 회귀를 확인한다.

## 운영상 제한과 다음 개선

- 학원망 외부 사용자를 논리적으로 구분했을 뿐 VLAN/라우팅으로 격리한 것은 아니다. 클라이언트에 다른 IP를 부여하거나 PC1~3에서 접속했다는 이유로 ADMIN 권한을 부여하지 않는다.
- NodePort 직접 접근 등 pfSense 우회 경로 차단은 별도다. 이 변경은 방화벽·SSH·DB·관제 제품 관리 UI를 개방하지 않는다.
- pfSense는 TLS를 k3s로 전달한다. pfSense의 Suricata가 암호화된 모든 HTTP 본문을 볼 수 있다고 가정하지 않는다. 앱/Nginx 감사 로그와 연계한다.
- 현재 SNAT 및 NodePort 경로는 앱에 원본 IP가 아닌 공통 주소를 보이게 할 수 있다. 앱의 `LOGIN_MAX_PER_IP=20` 또는 IP 자동 차단이 전체 사용자를 함께 제한할 수 있으므로 사용자 ID·세션 기준 기록과 함께 시험한다. IP 확인을 위해 임의 X-Forwarded-For 신뢰를 허용하거나 로그인 제한을 끄지 않는다. 원본 IP 보존은 별도 네트워크 설계 과제다.
- 외부 사용자에 관리자 로그인 경로를 제공하므로 강한 관리자 비밀번호·계정별 책임 추적이 필요하며 MFA·관리자 재인증을 후속 검토한다. 현재 MFA 구현 완료로 기록하지 않는다.

근거: [OWASP 권한 검사](https://cheatsheetseries.owasp.org/cheatsheets/Authorization_Cheat_Sheet.html), [Kubernetes ConfigMap](https://kubernetes.io/docs/concepts/configuration/configmap/). 최신 복구 결과는 [2026-10-27 기록](../operations/2026-10-27-service-recovery.md)을 참조한다.
