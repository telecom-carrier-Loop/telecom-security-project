# 환경변수 — 인프라 담당 / 전체

루트 [.env.example](../../.env.example)은 이름·가짜 주소·빈 Secret만 제공합니다. `.env`는 로컬에서 작성하고 Git에 올리지 않습니다. DATABASE_URL과 분리형 DB 변수를 혼용하지 않습니다.

| 변수 | 로컬 | 공용 PC |
|---|---|---|
| APP_ENV | local | lab |
| DB_HOST | mysql | 192.168.30.100 |
| DB_PORT / DB_NAME | 3306 / telecom | 동일 |
| DB_USER / DB_PASSWORD | 로컬 앱 전용 | 공용 앱 전용 |
| LOG_LEVEL / LOG_FORMAT | INFO / json | 동일 |
| INCIDENT_API_BASE_URL | http://internal-proxy:18081 | http://127.0.0.1:18081 |
| EVENT_RELAY_BASE_URL | http://event-relay:18090 | http://127.0.0.1:18090 |
| N8N_WEBHOOK_URL | http://n8n:5678/webhook/incident-v1 | http://127.0.0.1:5678/webhook/incident-v1 |

Secret: DB_PASSWORD, MYSQL_ROOT_PASSWORD(로컬 DB 초기화), INCIDENT_API_TOKEN, EVENT_INGEST_TOKEN, DISCORD_WEBHOOK_URL, N8N_ENCRYPTION_KEY. 토큰별 다른 값을 사용합니다. MySQL root와 앱 계정도 분리합니다. n8n 암호화 키는 데이터 볼륨과 함께 보호·백업합니다.

공용 n8n은 host 네트워크+loopback 수신, 로컬 Compose는 bridge 서비스 이름을 사용합니다. 컨테이너의 127.0.0.1은 호스트 주소가 아닙니다.
