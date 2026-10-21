# 기존 프로젝트 MySQL 8.4 복제 준비

## 확인된 상태

| 구분 | PC1 | PC2 |
|---|---|---|
| 주소 | 192.168.3.18 | 192.168.3.19 |
| 컨테이너 | flask_mysql | mysql-lab |
| MySQL | 8.4.11 | 8.4.11 |
| server_id | 1 | 2 |
| GTID / enforce_gtid_consistency | ON / ON, 영구 저장 | ON / ON, 영구 저장 |
| 프로젝트 DB | my_new_board_db, 22개 InnoDB 테이블 | my_new_board_db, 22개 테이블 |

이 절차는 기존 `flask_mysql`을 사용하는 프로젝트의 초기 동기화용이다. 빈 DB를 만드는 이전 `shared-pc.ps1` bootstrap이나 이전 5개/7개 테이블 백업을 사용하지 않는다. 정기 백업은 초기 동기화와 별도 작업으로 구성한다.

## PC1 인증서·계정·최신 백업 준비

Flask와 해당 DB에 쓰는 자동화를 잠시 중지한다. MySQL 컨테이너와 Docker Desktop은 유지한다. `mysql>`에서는 `exit;`로 나와 PowerShell에서 실행한다.

두 파일을 같은 디렉터리에 둔다. 저장소에 있는 파일을 실행하는 경우:

```powershell
powershell -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File infrastructure/tools/mysql84-primary-export.ps1 -RepositoryPath C:/Users/user/telecom-security-project -Action Prepare
```

현재 PC1 root 비밀번호를 **네 번** 입력한다. 순서는 원본 확인, TLS 갱신·계정 생성·쓰기 잠금, mysqldump, 쓰기 재개다. root 비밀번호를 파일에 보관하지 않는다. 복제 비밀번호는 난수로 생성하며 SQL 파일과 `.secrets` 안에 보관하고 명령 인수에 넣지 않는다.

도구는 다음 작업을 수행한다.

1. 검증된 업그레이드 상태의 실제 PC1 컨테이너·볼륨과 GTID·22개 InnoDB 테이블을 확인한다. 기존 `loop_repl` 계정이나 쓰기 잠금이 있으면 중단한다.
2. **기존 CA와 CA 개인 키를 PC1 안에서 유지**하며 PC1 IP와 localhost를 확인할 수 있는 새 서버 인증서와 PC2 전용 클라이언트 인증서를 발급한다. 기존 서버 인증서·키는 별도 보관한다.
3. 서버 인증서를 갱신하고 `loop_repl` 계정에 `REPLICATION SLAVE`만 부여한다. 비밀번호와 `/CN=loop-pc2-replica` 클라이언트 인증서가 모두 필요하다. Docker Desktop의 주소 변환을 고려해 MySQL Host는 `%`이며 PC1 방화벽의 PC2 주소 제한을 함께 사용한다. 계정 생성은 세션의 바이너리 로깅을 꺼서 다른 서버로 전달하지 않는다.
4. 실제 TLS 연결에서 서버 신원과 클라이언트 인증을 검사한다. 서버는 192.168.3.18과 127.0.0.1을 인증서 SAN으로 포함한다.
5. PC1 쓰기를 잠근 상태에서 GTID 정보가 포함된 새 앱 DB 백업을 생성한다. 테이블 개수, GTID 구문, 덤프 완료 표식을 검사하고 파일 SHA256을 계산한다.
6. 아래 PC2 전달 폴더를 완성하고 PC1 쓰기 잠금을 해제한다. 새 스냅샷 이후 변경은 복제가 연결되면 바이너리 로그에서 이어받아야 한다.

```text
C:\Users\user\telecom-security-project\.secrets\mysql84-replication\pc1\pc2-transfer
  snapshot.sql
  ca.pem
  client-cert.pem
  client-key.pem
  replication-password
  manifest.json
```

출력의 `MANIFEST_SHA256` 값은 따로 기록한다. 전달 폴더에는 업무 데이터, 클라이언트 개인 키, 복제 비밀번호가 있으므로 신뢰할 수 있는 비공개 경로로 PC2에 전달한다. GitHub·공개 채팅에 업로드하지 않는다. **이 폴더만 전달**하고 부모 폴더, 기존 서버 개인 키와 CA 개인 키는 PC1에 보관한다.

PC2에서는 아래 경로에 폴더를 배치한다. PC2의 기존 데이터 볼륨과 실행 인수를 확인한 뒤 백업·초기 복원·복제 채널 설정을 진행한다. 현재 준비 도구는 PC2 데이터를 변경하거나 복제를 시작하지 않는다.

```text
C:\Users\user\telecom-security-project\.secrets\mysql84-replication\incoming\pc2-transfer
```

## 오류와 상태 조회

`Prepare`를 다시 실행해 인증서·계정·기존 백업을 덮어쓰지 않는다.

```powershell
powershell -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File infrastructure/tools/mysql84-primary-export.ps1 -RepositoryPath C:/Users/user/telecom-security-project -Action Status
```

백업 또는 TLS 연결 확인 도중 오류가 나면 PC1이 쓰기 잠금 상태일 수 있다. 초기 내보내기가 중단된 상태에서 PC1 쓰기만 재개해야 하는 경우 다음 명령을 사용한다. 불완전한 전달 폴더를 정상 백업으로 표시하지는 않는다.

```powershell
powershell -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File infrastructure/tools/mysql84-primary-export.ps1 -RepositoryPath C:/Users/user/telecom-security-project -Action ResumePrimary
```

정상 완료 기준은 `Stage: export-ready`, `PrimaryResumed=true`, 전달 폴더와 해시 출력이다. 이는 **PC1 준비 완료**이며 PC2 복제 성공을 의미하지 않는다.

## 검증

Windows PowerShell 5.1에서 Docker 대역을 이용해 잘못된 볼륨, 공유 볼륨, SQL 실패, TLS 실패, 덤프 실패·누락, 재실행 차단, 해시와 비밀 전달 범위를 검사한다. 실제 OpenSSL로 CA·서버·클라이언트 인증서를 생성하여 IP·용도 검사와 잘못된 IP 거부도 확인한다. 실제 DB 연결과 백업은 공용 PC에서 실행 결과를 확인한다.

참고: [MySQL GTID 초기 구성](https://dev.mysql.com/doc/refman/8.4/en/replication-gtids-howto.html), [암호화 복제 연결](https://dev.mysql.com/doc/refman/8.4/en/replication-encrypted-connections.html).
