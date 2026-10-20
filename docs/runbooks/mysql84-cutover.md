# 인프라 담당: PC1 MySQL 8.4.11 전환

현재 전제는 PC1 `mysql-server`의 최종 백업을 별도 볼륨의
`loop-mysql84-check-20261020-114057-962`에 복원·검증한 상태다.
공용 PC의 Docker를 이 도구를 작성한 노트북에서 원격 실행한 것은 아니다.
실제 실행과 웹 기능 확인은 PC1에서 진행한다.

## 실행 순서

Flask와 팀원들의 DB 쓰기를 중지한 상태로 프로젝트 루트에서 실행한다.
React 5173, Flask 5000, MySQL 3306 포트는 유지한다.

```powershell
powershell -NoProfile -ExecutionPolicy RemoteSigned -File infrastructure/tools/mysql84-cutover.ps1 -Action prepare
powershell -NoProfile -ExecutionPolicy RemoteSigned -File infrastructure/tools/mysql84-cutover.ps1 -Action switch
powershell -NoProfile -ExecutionPolicy RemoteSigned -File infrastructure/tools/mysql84-cutover.ps1 -Action configure
```

각 명령의 `PASS`를 확인한 뒤 다음 명령을 실행한다. 오류가 나면 멈추고
`prepare`, `switch`, `configure` 중 실행한 항목과 오류를 전달한다.
도중 실패한 `switch`를 반복 실행하지 않는다.

- `prepare`: 원본/검증용 볼륨 분리와 MySQL 설정 확인, `loop_app` 계정 생성,
  전환용 root 비밀 파일과 실행 파일을 `.secrets/mysql84-cutover/`에 보관한다.
- `switch`: 두 서버를 정상 종료하고 원본 26.7 컨테이너를 이름 변경하여 보관한다.
  8.4 전용 데이터 볼륨과 복사한 읽기 전용 비밀 파일로 새 `mysql-server`를 생성한다.
  mount 확인 후 시작하며, 기동·설정·호스트 3306 연결을 확인한다.
  중복 기동 방지를 위해 검증 컨테이너만 제거하며 `-v`는 사용하지 않는다.
- `configure`: 저장소 루트와 `backend/`의 기존 `.env`를 비밀 폴더에 백업한 후
  `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`만 갱신한다.
  두 파일이 모두 없으면 `backend/.env`를 생성한다. 그 외 설정은 보존한다.
  현재 앱은 루트 `.env`를 먼저 읽으므로 두 기존 파일에 같은 DB 설정을 적용한다.

`loop_app`은 해당 앱 DB의 조회·등록·수정·삭제 및 프로시저 실행 권한을 갖는다.
테이블 생성/변경 권한은 주지 않는다. 나중의 스키마 변경은 별도 관리자 세션이나
팀의 마이그레이션 절차로 PC1에 적용한다.

이 단계의 DB 공개 주소는 `127.0.0.1:3306`이다. PC2의 원격 복제 연결은
아직 열지 않는다. 다음 단계에서 TLS와 학원망의 PC2 접근 제한을 함께 설정한다.

## 웹 확인

기존 Flask 터미널에서 이전 DB 환경변수가 `.env`를 덮어쓰지 않도록 제거한다.
Python 가상환경은 평소 사용하는 환경을 그대로 활성화한다.

```powershell
Remove-Item Env:DB_HOST,Env:DB_PORT,Env:DB_NAME,Env:DB_USER,Env:DB_PASSWORD -ErrorAction SilentlyContinue
Set-Location backend
python app.py
```

React는 기존 명령과 5173 포트로 실행한다. 로그인, 기존 데이터 조회,
테스트 게시글 등록·수정·삭제를 확인한다. 등록은 새 서버에 쓰기가 시작되는 시점이다.
Flask에서 DDL 권한 오류가 발생해도 앱 계정을 root로 바꾸지 말고
필요한 마이그레이션을 먼저 확인한다.

## PC1과 PC2의 테이블이 다를 때

복제 연결 전에는 테이블이 달라도 PC1 전환을 진행할 수 있다. 차이를 그대로 둔 채
복제부터 시작하면 테이블 누락·열 차이·키 충돌로 복제가 중단될 수 있다.

초기 동기화는 다음 순서로 진행한다.

1. PC1 8.4.11을 기준 DB로 확정하고 PC2도 8.4.11인지 확인한다.
2. PC2의 보존할 최신 변경이 없는지 확인하고 기존 백업을 보관한다.
   사용자는 기존 PC2 앱 DB를 덮어써도 된다고 확인했지만,
   이후 팀원이 PC2에만 추가한 데이터가 있다면 새로 보존해야 한다.
3. PC1의 일관된 백업과 GTID 상태로 PC2의 `my_new_board_db`를 초기화한다.
   다른 DB와 전체 Docker 볼륨을 삭제하지 않는다.
4. PC1 `server_id=1`, PC2 `server_id=2`, GTID, TLS, 복제 전용 계정을 설정한다.
5. 두 DB의 테이블 정의와 데이터, 복제 스레드 상태를 확인하고 PC2를 읽기 전용으로 둔다.
6. 이후 테이블 추가·변경은 PC1의 승인된 마이그레이션으로만 수행하고 PC2 반영을 확인한다.

PC2의 Flask도 게시글 쓰기 등 일반 서비스 DB 연결은 PC1 Primary로 향해야 한다.
PC2 Replica를 일반 쓰기 대상에 넣지 않는다. 초기 복제가 끝나면
정기 백업, 별도 저장, 복구 리허설을 진행하고 Nginx 웹 분산으로 넘어간다.
복제만으로 삭제·잘못된 수정까지 되돌릴 수는 없다.

## 전환 도중 실패했을 때

비밀 값 대신 상태 파일의 `Stage`만 확인한다.

```powershell
$loopState = Get-Content .secrets/mysql84-cutover/state.json -Raw | ConvertFrom-Json
$loopState.Stage
```

- `prepared`, `candidate-stopped`: 원본이 보존되어 있으므로 임의 삭제 없이 오류를 확인한다.
- `source-renamed`, `created`, `started`: Flask를 중지한 채 상태를 전달한다.
  새 컨테이너와 검증 컨테이너를 같은 볼륨으로 동시에 시작하지 않는다.
- `switched`: 새 서버로 전환된 상태다. 원본 컨테이너의 이름은 `RollbackName`에 있다.

**새 서버에 애플리케이션 쓰기가 전혀 없었던 경우에만** 아래 원본 복귀를 사용할 수 있다.
등록·수정·삭제가 시작됐다면 먼저 새 DB를 백업하고 변경 데이터의 보존 방법을 결정한다.

```powershell
& {
    $ErrorActionPreference = 'Stop'
    $loopState = Get-Content .secrets/mysql84-cutover/state.json -Raw | ConvertFrom-Json
    if ($loopState.NewId) {
        docker stop --time 60 $loopState.NewId
        if ($LASTEXITCODE -ne 0) { throw '새 서버 중지 실패' }
        docker rename $loopState.NewId ('mysql-server-84-paused-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
        if ($LASTEXITCODE -ne 0) { throw '새 서버 이름 변경 실패' }
    }
    $loopOriginal = (docker inspect $loopState.SourceId | ConvertFrom-Json)[0]
    if ($LASTEXITCODE -ne 0) { throw '원본 조회 실패' }
    if ($loopOriginal.Name -ne '/mysql-server') {
        docker rename $loopState.SourceId mysql-server
        if ($LASTEXITCODE -ne 0) { throw '원본 이름 복구 실패' }
    }
    $loopRestart = $loopState.SourceRestartPolicy.Name
    if (-not $loopRestart) { $loopRestart = 'no' }
    if ($loopRestart -eq 'on-failure' -and $loopState.SourceRestartPolicy.MaximumRetryCount -gt 0) {
        $loopRestart += ':' + $loopState.SourceRestartPolicy.MaximumRetryCount
    }
    docker update ('--restart=' + $loopRestart) $loopState.SourceId
    if ($LASTEXITCODE -ne 0) { throw '원본 재시작 정책 복구 실패' }
    docker start $loopState.SourceId
    if ($LASTEXITCODE -ne 0) { throw '원본 기동 실패' }
}
```

`configure`까지 실행했다면 `.secrets/mysql84-cutover/`의 `repo-env.before`,
`backend-env.before`를 대응하는 원래 `.env`에 복구한다. 새로 만든 `.env`는
그 안의 DB 설정을 원래 값으로 되돌린다. 원본 재기동 후 쓰기 금지 상태와
앱 연결을 확인한 다음 서비스 재개 여부를 결정한다. 전환 도구를 다시 실행하기 전에
상태 파일과 컨테이너 이름을 함께 점검한다.

비밀 폴더, 원본 DB 볼륨, 백업을 정리 대상으로 삭제하지 않는다.
