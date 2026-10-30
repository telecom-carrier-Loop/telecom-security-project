# PC1·PC2 브라우저 인증서 등록 안내

작성일: 2026-10-30 (Asia/Seoul)

## 증상과 범위

PC1·PC2의 Chrome에서 프로젝트 또는 Wazuh 웹 페이지를 열 때 다음 오류가 보고됐다.

```text
NET::ERR_CERT_AUTHORITY_INVALID
```

이 코드는 브라우저가 서버 인증서의 발급자를 신뢰하지 못할 때 나타난다. 이번 안내는 팀 실습용 CA를 각 Windows 사용자의 신뢰 루트에 등록하는 절차다. 다른 인증서 오류 코드는 SAN·유효기간·서버 인증서 체인 등을 별도로 확인한다.

PC3에 등록한 인증서 신뢰는 PC1·PC2로 자동 전파되지 않는다. 실제 접속 주소·내부 IP·포워딩/NAT 설정·인증서 지문은 이 공개 문서에 포함하지 않고 팀의 별도 인수인계 자료에서 확인한다.

## 1. 필요한 공개 CA 받기

팀 담당자에게 확인된 공개 CA를 전달받는다.

| 대상 | 파일 | 인증서에서 확인할 발급자 정보 |
|---|---|---|
| 프로젝트 웹·관리자 페이지 | `lab-ca.crt` | `Telecom Lab Root CA` |
| Wazuh Dashboard | `wazuh-dashboard-ca.crt` | `O=Wazuh, OU=Wazuh` |

프로젝트만 이용하면 `lab-ca.crt`가 필요하고, Wazuh도 이용하면 Wazuh CA를 추가로 등록한다. 이 문서 커밋에는 인증서 파일과 ZIP을 포함하지 않는다.

전달 대상은 공개 `.crt` 파일이다. CA 개인키와 서버 개인키는 옮기거나 레포에 올리지 않는다.

## 2. 파일 저장과 확인

PC1·PC2 각각에서 Chrome을 사용하는 Windows 계정의 Downloads 폴더에 필요한 파일을 저장한다. **Windows PowerShell**에서 실행한다. Ubuntu VM 터미널에서 실행하는 명령이 아니다.

```powershell
Test-Path -LiteralPath "$env:USERPROFILE\Downloads\lab-ca.crt"
Test-Path -LiteralPath "$env:USERPROFILE\Downloads\wazuh-dashboard-ca.crt"
```

사용할 파일이 `True`인지 확인한다. `False`이면 다운로드·압축 해제 위치와 파일명을 먼저 확인한다.

```powershell
Get-FileHash -LiteralPath "$env:USERPROFILE\Downloads\lab-ca.crt" -Algorithm SHA256
Get-FileHash -LiteralPath "$env:USERPROFILE\Downloads\wazuh-dashboard-ca.crt" -Algorithm SHA256
```

해시를 담당자가 별도로 전달한 예상 SHA256과 대조한다. 파일이 없거나 해시가 다르면 등록을 멈추고 원본을 확인한다. 향후 CA를 갱신하면 예상 해시도 함께 갱신해야 한다.

## 3. 현재 사용자 신뢰 루트에 등록

필요한 공개 CA의 원본 확인이 끝나면 PC1·PC2 각각에서 해당 명령을 실행한다.

```powershell
# 프로젝트 웹·관리자 페이지용
certutil -user -addstore Root "$env:USERPROFILE\Downloads\lab-ca.crt"

# Wazuh Dashboard용
certutil -user -addstore Root "$env:USERPROFILE\Downloads\wazuh-dashboard-ca.crt"
```

설치 확인 창에서는 위 표의 인증서 정보가 맞는지 확인한다. 이 작업은 해당 CA가 서명한 인증서를 현재 Windows 사용자가 신뢰하게 한다. `-user` 옵션으로 현재 사용자 저장소에 등록하며, 다른 PC나 다른 Windows 계정에 자동 등록되지는 않는다.

## 4. Chrome 재시작과 접속 확인

1. Chrome에서 작성 중인 작업을 저장한다.
2. Chrome 창을 모두 종료하고 다시 실행한다. 필요하면 주소창의 `chrome://restart`를 사용한다.
3. 팀에서 전달한 프로젝트와 Wazuh 주소를 열어 인증서 경고 없이 접속되는지 확인한다.
4. 경고가 남으면 정확한 오류 코드를 기록해 담당자에게 전달한다.

PC3에서는 CA 등록 전부터 실행 중이던 Chrome의 경고가 재시작 후 해소됐다는 사용자 확인을 받았다. PC1·PC2의 등록·재접속 완료는 아직 확인하지 못했다. 고급 메뉴로 경고를 통과한 결과와 경고 없는 정상 접속을 구분한다.

## 5. 별도로 남아 있는 프로젝트 IP 차단

다음 화면 메시지는 인증서 경고와 별개다.

> 보안 정책에 따라 접근이 차단되었습니다. 문제가 있으면 고객센터로 문의하세요.

조회한 프로젝트 코드에서는 접속 IP가 활성 차단 대상이면 세션 로드 전에 `IP_BLOCKED`·HTTP 403을 반환한다. 따라서 ADMIN 계정이어도 로그인 전에 차단될 수 있다. CA 등록으로 이 차단이 해제되지는 않는다.

남은 작업은 인증된 서버 관리 경로에서 실제 인식 IP·활성 차단 사유·자동화 기록을 확인하고, 필요한 대상만 해제한 뒤 재차단 여부를 확인하는 것이다. 현재 실제 차단 IP와 등록 원인·해제 성공은 확정하지 않았다.

## 6. 완료 확인표

- [ ] PC1에서 필요한 공개 CA의 파일명·해시 확인.
- [ ] PC1의 현재 사용자 신뢰 루트에 등록하고 Chrome 재시작.
- [ ] PC2에서 필요한 공개 CA의 파일명·해시 확인.
- [ ] PC2의 현재 사용자 신뢰 루트에 등록하고 Chrome 재시작.
- [ ] 프로젝트와 Wazuh의 인증서 경고 없는 접속 확인.
- [ ] 프로젝트 IP 차단 원인 확인과 필요한 대상 해제.
- [ ] 프로젝트 ADMIN 로그인 및 도구별 자체 로그인·새로고침·조회 확인.

이 문서는 클라이언트 등록 절차를 공유하는 기록이며 서버 인증서나 방화벽·DB 설정을 자동 변경하지 않는다.

