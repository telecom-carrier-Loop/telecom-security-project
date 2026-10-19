# 공용 PC 복제 초기화 — B

로컬 db-lab은 빈 합성 DB에만 사용합니다. 공용 서버나 이미 데이터가 있는 DB에 lab 초기화 스크립트를 연결하지 않습니다.

1. 양쪽 MySQL 8.4 패치·server_id·GTID 설정을 맞춥니다. Primary/Replica 초기화 중 read-only 설정이 공식 이미지 최초 계정 생성을 막지 않도록 초기 부팅과 보호 설정을 분리합니다.
2. A와 스키마·쓰기 중단 시점을 정하고 Primary의 일관된 스냅샷/백업과 GTID 기준점을 준비합니다. 단순 디렉터리 복사·빈 Replica 채널 연결로 기존 데이터를 복구하지 않습니다.
3. 전용 복제 계정은 PC2 DB 주소로 제한하고 REQUIRE SSL을 적용합니다. 양 서버의 실제 인증서 SAN·CA·파일 권한을 확인합니다.
4. Replica에 일관된 초기 데이터를 복원하고, 검증한 CA·서버 식별과 `SOURCE_AUTO_POSITION=1`로 채널을 설정합니다. production에서는 `SOURCE_SSL_VERIFY_SERVER_CERT=1`을 사용하고 TLS 인증 실패를 우회하지 않습니다.
5. 복제 수신/적용 thread·오류·GTID와 합성 거래를 확인한 뒤 read_only/super_read_only를 영속 적용합니다.
6. 앱 계정 쓰기 거부·재시작 후 복제 복귀·백업 복원을 검증합니다. A의 Migration은 Primary에서 한 번만 실행합니다.

DB VIP는 수동이며, MySQL이 VIP를 받기 전에도 시작할 수 있도록 호스트 바인딩과 C의 인터페이스별 방화벽을 함께 검증합니다.
