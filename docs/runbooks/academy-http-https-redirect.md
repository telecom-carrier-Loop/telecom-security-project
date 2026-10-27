# HTTP 접속을 공통 HTTPS 주소로 이동 — 적용 전 절차

2026-10-28 작성. **아직 현장 적용하지 않았다.** 현재 운영443 HAProxy의 readiness200을 확인했으나 운영30회·역할회귀·자동DOWN의 확인 항목은 남아 있다. 이 문서는 다음 설정 안내이며 성공 기록이 아니다.

목표: `http://192.168.3.30/경로?쿼리`로 들어온 브라우저에 `https://192.168.3.30/경로?쿼리`로 이동하라는 응답을 반환한다. 첫 HTTP 요청을 암호화하는 기능은 아니므로 로그인·API 호출은 처음부터HTTPS를 사용한다. PC2 n8n은기존HTTPS10443을그대로사용한다.

## 1. 관리 경로·80 포트 사전 확인

1. PC3에서 `https://192.168.50.1:8444` 관리 로그인과 pfSense VM 콘솔 접근을 확보한다.
2. Diagnostics → Backup & Restore에서 현재 설정을 개인 경로에 저장한다. 설정XML을Git에첨부하지않는다.
3. pfSense Shell에서 조회한다.

```sh
sockstat -4 -6 -l | grep -E ':(80|443|8444|11443)[[:space:]]'
```

4. Firewall → NAT → Port Forward에 .3.30:80 또는 이를 포함하는 범용규칙이 없는지 확인한다. 8080 규칙은80과다르다.
5. nginx가*:80을사용하면 System → Advanced → Admin Access → WebGUI Redirect에서 **Disable webConfigurator redirect rule**을체크하고Save한다. pfSense관리용HTTP리다이렉트만해제한다. 관리Protocol HTTPS/TCP8444/인증서는유지하고anti-lockout은해제하지않는다.
6. 다시조회해80이비어있고관리8444와서비스443/11443이유지되는지확인한다. 다른프로세스가80을점유하면중단하고그대상부터식별한다.

관리HTTP리다이렉트를그대로두면사용자가웹사이트대신pfSense관리8444로이동할수있다. 관리서비스를kill하거나HTTP로변경하지않는다.

## 2. 리다이렉트 전용 Frontend

Services → HAProxy → Frontend → Add. 기존TCP443/11443 Frontend를편집하지않는다.

| 항목 | 값 |
|---|---|
| Name | telecom-http-redirect |
| Status | Active |
| Listen address | Use custom address |
| Custom address / Port | 192.168.3.30 / 80 |
| SSL Offloading | 해제 |
| Type | http |
| Default Backend | None |
| Advanced settings → Advanced pass thru | 아래한줄 |

```haproxy
http-request redirect prefix https://192.168.3.30 code 302
```

이문장은 **Frontend의 Advanced pass thru**에입력한다. External address행의Advanced,Bind pass thru,Backend입력란에는넣지않는다. 고정HTTPS주소를사용하고원래경로/쿼리는유지한다. 시험중영구캐시를피하기위해302를사용한다. HAProxy가직접리다이렉트를응답하므로HTTP백엔드나TLS개인키는추가하지않는다.

Save/Apply에서오류가나면진행하지않는다. 80리스닝을확인한다.

```sh
sockstat -4 -l | grep -E ':(80|443)[[:space:]]'
```

## 3. WAN 허용 규칙

Firewall → Rules → WAN → Add.

| 항목 | 값 |
|---|---|
| Action / Interface / Address Family / Protocol | Pass / WAN / IPv4 / TCP |
| Source / Source Port | Network 192.168.3.0/24 / Any |
| Destination | Address or Alias 192.168.3.30 |
| Destination Port | HTTP 80 |
| Description | telecom-http-redirect-80 |
| Advanced Gateway | default |
| Disable reply-to | 체크 |

Save → Apply Changes를 누른다. 서비스 접근을 차단하는 명시적 Block이 있으면 허용 규칙을 그 앞에 배치한다. NAT Port Forward는 추가하지 않는다.

## 4. PC2 Windows 검증

먼저 자동으로 따라가지 않고 Location을 확인한다.

```powershell
curl.exe --noproxy '*' --connect-timeout 3 --max-time 10 -sS -D - -o NUL 'http://192.168.3.30/api/health/ready?redirect_probe=1'
```

기대값은 HTTP302와 Location `https://192.168.3.30/api/health/ready?redirect_probe=1`이다. 관리8444로 이동하거나 pfSense 로그인 HTML이 나오면 잘못된 경로다.

프로젝트 CA를 신뢰한 PC에서 HTTPS까지 따라간다.

```powershell
curl.exe --noproxy '*' --ssl-revoke-best-effort --connect-timeout 3 --max-time 15 --max-redirs 3 -L -sS -o NUL -w 'HTTP=%{http_code} FINAL=%{url_effective}\n' 'http://192.168.3.30/api/health/ready?redirect_probe=1'
```

기대값은 최종 HTTP200과 같은 경로/쿼리를 가진 HTTPS443 FINAL 주소다. 인증서 검증을 끄지 않는다. 브라우저에도 `http://192.168.3.30/`을 명시해 입력하고 공개 웹으로 이동하는지 확인한다. IP만 입력하면 브라우저가 방문 기록이나 HTTPS 우선 기능을 사용할 수 있어 서버 리다이렉트의 증거가 되지 않는다.

## 5. 실패 시 복구와 남은 작업

- 새 Frontend `telecom-http-redirect`와 WAN 규칙 `telecom-http-redirect-80`만 비활성화하고 Save/Apply한다. 기존 HTTPS443과 관리8444를 유지하고 HTTPS로 직접 접속한다.
- HTTP80 이동 설정 때문에 이전443 NAT나 n8n10443을 변경하지 않는다.
- 성공 후 현장 결과를 기록하고 운영443의30회 분산·역할별 권한·공개internal404를 확인한다. CA가 등록되지 않은 PC는 별도로 프로젝트 CA를 신뢰하도록 설정해야 한다.

## 근거

- [Netgate 관리 GUI와 WebGUI Redirect](https://docs.netgate.com/pfsense/en/latest/config/advanced-admin.html#webgui-redirect)
- [HAProxy HTTP redirects](https://www.haproxy.com/documentation/haproxy-configuration-tutorials/proxying-essentials/custom-rules/http-redirects/)
- [pfSense HAProxy Frontend UI](https://github.com/pfsense/FreeBSD-ports/blob/devel/net/pfSense-pkg-haproxy/files/usr/local/www/haproxy/haproxy_listeners_edit.php)
