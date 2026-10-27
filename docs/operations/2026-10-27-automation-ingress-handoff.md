# 2026-10-27 자동화 API 입구 적용 결과와 n8n 담당자 인계

기준: Asia/Seoul. 현장 사용자 화면·보고를 근거로 기록했다. 문서 작성 환경에서 현장 서버에 직접 접속하거나 시험하지 않았다.

**현재 상태: k3s 신규 프록시 배포 및 PC2 Windows에서 미인증 API 도달 확인. n8n 설정·실제 자동화와 다른 PC 차단은 미검증.** 사용자는 n8n 관련 확인·변경을 10월 28일 담당자와 상의하여 진행하기로 했다. 일반 PC 시험도 내일 가능하다고 답했다.

## 확인된 결과

| 항목 | 근거·판정 |
|---|---|
| API 사전 검사 | 두 API Pod에서 5개 내부 API의 토큰 설정·선행 인증 검사·미인증401 검사 통과 화면 확인 |
| Plan | PLAN OK. 기존 edge의 임시 설정 nginx -t 및 신규 리소스 server dry-run을 통과하는 절차 완료 |
| 신규 Deployment | telecom-automation-edge: READY 2/2, AVAILABLE 2 |
| 신규 Pod | PC1 pc1-k3s와 PC2 pc2-k3s에 각각 1/1 Running, 당시 재시작0 |
| 신규 Service | NodePort, ClusterIP 10.43.163.165, 443:30445/TCP 화면 확인 |
| 도구 상태 | applied-needs-pfsense-n8n-tests. 도구가 외부 연동 성공을 자동 판정하는 완료 상태가 아님 |
| PC2 → 서비스10443 | 사용자가 TcpTestSucceeded True 보고 |
| PC2 → POST10443/api/internal/incident-events | HTTP401, JSON UNAUTHORIZED. Authorization/X-API-Key 없이 API에 도달하여 거부됨. 응답 Date 2026-10-27 10:28:43 GMT(19:28:43 KST) |
| 공개443 내부 API | 처음에는 명령 중복 붙여넣기 오류가 있었으나, 후속으로 안내한 단독 readiness200 및 내부 API404 시험이 모두 기대값과 같았다고 사용자 보고 |
| 공개443 readiness | 위 후속 시험에서 HTTP200 / database ok 기대값 일치 사용자 보고. 별도 원문 출력은 미첨부 |
| 브라우저 →10443/incident-events | GET으로 접근해 Nginx405 화면 확인. 이 경로는 POST 전용이므로 정상 메서드 제한이며 추가 개방 사유가 아님 |
| 일반 PC →10443 | 10월28일 확인 예정. PC2만 허용됨을 아직 입증하지 못했으므로 완료 표시하지 않음 |
| n8n 컨테이너 →10443 | CA 신뢰·URL·토큰·본문·실제 이벤트 처리 모두 미확인. Windows curl 성공과 구분 |

401은 비밀번호 오류나 DB 장애를 뜻하지 않는다. 이번 요청은 토큰을 보내지 않았으므로 정상 거부다. 유효 토큰으로 처리·DB 저장·Discord 전송까지 성공했다는 의미는 아니다.

브라우저405, 토큰 없는POST401, 유효 토큰·유효 본문의 최초POST201은 서로 다른 검사다. 브라우저에서405가 보인다는 이유로 GET이나 내부 경로 전체를 허용하지 않는다. 현재 전용 입구는 역할표의 정확한5개 경로·메서드만 전달하며 `/api/internal/*` 모든 경로를 일괄 개방하지 않는다.

## 의도한 연결 정책과 인계 값

```text
PC2 Windows Docker n8n (192.168.3.19)
  → PC3 pfSense WAN IP Alias 192.168.3.30:10443
  → DNAT 192.168.7.185:30445 / SNAT 192.168.3.30
  → telecom-automation-edge (PC1/PC2 각1개)
  → telecom-api:5000
```

| 위치 | 의도한 값 |
|---|---|
| Port Forward Source | Address or Alias: 192.168.3.19, source port Any |
| Port Forward Destination | Address or Alias: 192.168.3.30, TCP10443 |
| Redirect | 192.168.7.185:30445 |
| 연동 WAN 필터 | 원본 Source .3.19, 변환 후 Destination .7.185:30445, Gateway default, Disable reply-to |
| Hybrid Outbound NAT | Source .3.19/32 → Destination .7.185/32:30445, Translation .3.30/32 |
| k3s Service | telecom-automation-edge, NodePort30445, externalTrafficPolicy Local |
| 공개 서비스443 | /api/internal 및 /api/internal/* 차단 유지 |

이 표는 안내한 정책이다. PC2 통신 성공만으로 pfSense의 모든 최종 필드·규칙 순서나 다른 출발지 차단을 검증한 것은 아니다. 최종 설정 백업·규칙 화면과 다른 PC 차단 시험을 함께 보관한다. Nginx가 보는 SNAT 주소 .3.30 허용만으로 PC2 원본 제한을 대신할 수 없다.

## n8n 작업 전에 남은 확인 — 현장에서 실행할 읽기·미인증 시험

아래 시험은 토큰을 전송하지 않고 실제 차단·잠금·권한 회수·인시던트 생성을 수행하지 않는다. 미인증 시도 로그는 남을 수 있다. 결과는 아직 실행 완료로 기록하지 않았다.

### PC1 Ubuntu: 배포 상태와 출발지 보존 설정

```bash
loopAutomationWork="$(cat "$HOME/.telecom-automation-workdir")"
sudo -v
python3 "$HOME/k3s-automation-ingress.py" status --work-dir "$loopAutomationWork"
sudo k3s kubectl -n telecom get service telecom-automation-edge \
  -o jsonpath='{.spec.externalTrafficPolicy}{"\n"}'
sudo k3s kubectl -n telecom get pods -l app=telecom-api -o wide
```

기대값: 신규 edge 2/2, 노드별1개, Local, 기존 API 두 Pod 1/1. 정상 상태에서 apply나 rollback을 추가로 실행하지 않는다. 작업 폴더 경로는 위 pointer 파일과 함께 보존한다.

### PC2 Windows PowerShell: 공개 서비스·내부 API5개·경로 제한

한 블록으로 실행해 명령이 붙는 오류를 피한다. HTTP 코드와 curl 종료 코드만 표시하며 토큰/쿠키를 요구하지 않는다.

```powershell
$loopChecks = @(
    @{ Name='공개 readiness'; Method='GET'; Url='https://192.168.3.30/api/health/ready'; Expected='200' }
    @{ Name='공개 내부 API 차단'; Method='GET'; Url='https://192.168.3.30/api/internal/privilege-violations'; Expected='404' }
    @{ Name='사고 수신 미인증'; Method='POST'; Url='https://192.168.3.30:10443/api/internal/incident-events'; Expected='401' }
    @{ Name='IP 차단 미인증'; Method='POST'; Url='https://192.168.3.30:10443/api/internal/ip-blocks'; Expected='401' }
    @{ Name='계정 잠금 미인증'; Method='POST'; Url='https://192.168.3.30:10443/api/internal/account-locks'; Expected='401' }
    @{ Name='권한 조회 미인증'; Method='GET'; Url='https://192.168.3.30:10443/api/internal/privilege-violations'; Expected='401' }
    @{ Name='권한 회수 미인증'; Method='POST'; Url='https://192.168.3.30:10443/api/internal/role-revocations'; Expected='401' }
    @{ Name='전용 입구의 관리자 API 차단'; Method='GET'; Url='https://192.168.3.30:10443/api/admin/dashboard'; Expected='404' }
)
$loopResults = foreach ($loopCheck in $loopChecks) {
    $loopHttp = & curl.exe --noproxy '*' --ssl-revoke-best-effort --connect-timeout 3 --max-time 10 -sS -o NUL -w '%{http_code}' -X $loopCheck.Method $loopCheck.Url
    $loopCurlExit = $LASTEXITCODE
    [pscustomobject]@{
        Test = $loopCheck.Name
        HTTP = $loopHttp
        Expected = $loopCheck.Expected
        CurlExit = $loopCurlExit
        Pass = ($loopCurlExit -eq 0 -and $loopHttp -eq $loopCheck.Expected)
    }
}
$loopResults | Format-Table -AutoSize
```

모두 Pass=True가 기대값이다.

PC2 브라우저에서 공개 사이트의 고객 화면과 같은 주소에 다시 로그인한 ADMIN의 관리 화면도 확인한다. 화면에서는 일반 조회만 진행하고 내부 API의 유효 토큰 시험은 담당자와 함께할 작업으로 남긴다.

### 일반 PC: 10월28일 확인

PC1·PC2·PC3 이외의 일반 학원 PC에서 실행한다.

```powershell
Test-NetConnection 192.168.3.30 -Port 10443
Test-NetConnection 192.168.3.18 -Port 3306
Test-NetConnection 192.168.3.19 -Port 3306
```

세 항목 모두 TcpTestSucceeded=False가 기대값이다. 같은 PC의 CA 신뢰를 확인한 뒤 공개443의 일반 웹 접속 성공도 확인한다. 10443이 True라면 PC2 제한 완료로 처리하지 말고 pfSense의 광범위 pass/NAT와 기존 state를 확인한다.

## 10월28일 n8n 담당자에게 인계할 작업

1. 먼저 위의 일반 PC 차단 시험을 진행한다.
2. PC2 n8n의 실제 컨테이너 이름, Compose 서비스/파일, 데이터 마운트와 기존 암호화 키 보관 방식을 담당자와 확인한다. 비밀값은 공유하지 않는다.
3. 공개 CA만 컨테이너에 연결하고 기존 데이터를 유지하면서 CA 설정을 반영한다. Windows 인증서 등록만으로 n8n Node.js의 신뢰를 보장하지 않는다.
4. URL을 `https://192.168.3.30:10443/api/internal/...`로 변경하고 Credential에서 INCIDENT_API_TOKEN / AUTOMATION_API_TOKEN을 용도별로 참조한다. 값을 문서나 Git에 쓰지 않는다.
5. 실제 컨테이너에서 미인증401, 담당자와 함께 유효 토큰 시험, 시험 이벤트의 최초201/중복200/본문 충돌409 및 관리자 화면 기록을 확인한다.
6. IP 차단·계정 잠금·관리자 권한 회수는 합의한 시험 대상에만 검증한다. Discord 전송 성공은 API 처리 성공과 별도로 확인한다.

상세 절차: [학원망 자동화 API 입구 절차](../runbooks/academy-automation-ingress.md). 오늘 확인된 기록과 위 미실행 항목을 구분한다.

## 추적과 완료 조건

- 관련 구현: [PR #42](https://github.com/telecom-carrier-Loop/telecom-security-project/pull/42). 머지됐으나 실제 운영 완료 판정과 구분한다.
- 공유 이슈: [Issue #40](https://github.com/telecom-carrier-Loop/telecom-security-project/issues/40). 미확인 항목이 있으므로 진행 중으로 유지한다.
- 이중화는 [현황·단계별 시험](../runbooks/academy-ha-assessment.md)을 참조한다. 프록시2개 배포가 PC1 전체 장애의 자동 승계를 의미하지 않는다.
- [x] k3s Plan/Apply 및 Pod2개 Ready 화면 확인.
- [x] PC2 Windows TCP10443 성공·POST incident-events 미인증401 확인.
- [x] 공개443의 정확한 단독 URL404 및 readiness200 기대값 일치 사용자 보고.
- [x] 브라우저의 POST 전용 incident-events GET405 화면 확인.
- [ ] PC2 Windows에서 내부 API5개 미인증401 및 기존 웹 회귀 확인.
- [ ] 일반 PC10443 차단 및 DB 포트 차단 재확인.
- [ ] pfSense 최종 설정 백업 및 Service Local 추가 증거 보관.
- [ ] n8n CA·Credential·실제 이벤트·Discord까지 연동 시험.
