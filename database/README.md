# 데이터베이스 — A / B

| 위치 | 담당 | 용도 |
|---|---|---|
| schema/ | A | ERD·참고 SQL, ORM/Migration과 별도 최신본을 만들지 않음 |
| migrations/ | A | 스키마 변경 정본, Flask-Migrate 디렉터리 |
| seed/ | A | 합성 계정·서비스 데이터 |
| replication/ | B | MySQL 8.4 GTID 비동기 복제 |
| backup/ | B | 암호화 독립 백업·별도 DB 복원 |
| runbooks/ | B | 수동 승격·DB VIP 이동·격리·복귀 |

Migration은 B의 배포 전 단일 작업으로 Primary에 한 번 실행합니다. 앱 계정에는 DDL/복제/승격 권한을 부여하지 않습니다. DB VIP는 192.168.30.100이며 자동 승격하지 않습니다. 실제 덤프와 자격증명은 저장하지 않습니다.
