# Graylog / Wazuh 신규 테스트 스크립트 안내 (2026-10-22)

첨부된 기존 테스트 5개(ED-01, ED-04/08, ED-05, ED-06/ED-07, ED-09)와 **중복하지 않는** 추가 테스트입니다.

- K09: 3개 (PCAP 통계 **모의** GELF 이벤트)
- EX: 8개 (추가 공방전 규칙별 모의 GELF 이벤트)
- Wazuh 신규 Rule ID 100230~100237: 8개 (Wazuh 경보 **형식의 모의** GELF 이벤트)
- Wazuh 룰 엔진 확인: 보조 1개 (`wazuh-logtest` 입력 예시)

모든 `.txt`의 주 테스트는 **Windows PowerShell** 명령어입니다. 파일을 텍스트 편집기로 열고 전체 코드를 PowerShell에 붙여넣어 실행하세요. 확장자를 `.ps1`로 바꿀 필요가 없습니다.

## 사전 조건
- Windows Docker Graylog GELF UDP Input: `127.0.0.1:12201` 접근 가능
- Graylog 웹: `http://localhost:9000`
- 수신 검색: `test_source:GL-WZ-ADDITIONAL-20261022`
- 검색 시간: Last 15 minutes
- n8n 워크플로 EX / K09 / Wazuh Webhook이 실제 활성화되어야 Discord까지 확인 가능
- IP는 `198.51.100.0/24`, `192.0.2.0/24` 예시용 예약 주소를 사용하며 외부 호스트에 공격 트래픽을 보내지 않습니다.

## 비활성화 규칙 주의
- **ED-EX-03:** Low & Slow 이벤트 현재 비활성화. 독립된 `rule:login-low-slow` 필드가 실제 탐지 로직으로 생성돼야 의미 있음.
- **ED-EX-07:** Wazuh로 역할 분리하여 비활성화. 켜지 말고 Wazuh FIM 쪽 검증 권장.
- **ED-WZ-02:** 생성 직후 비활성화. 수신 로그는 보여도 이벤트/알림이 생성되지 않음. 경보 검증은 이벤트 활성화 필요.

## 테스트의 의미
1. `tcpdump` 및 실 PCAP으로부터 생성한 통계가 아닌 K09 테스트는 **형식/임계치/전송 경로만** 검증합니다.
2. Wazuh 테스트에서 `_wazuh_rule_id` 필드는 Graylog가 `wazuh_rule_id`로 색인합니다. 이는 **실제 Wazuh가 해당 규칙을 실행했다는 증거가 아닙니다**.
3. EX-04는 실제 KST 심야 로그인이 아닌 `night-login`으로 **이미 분류된 모의 이벤트**입니다.
4. UDP 전송 성공 메시지는 수신 성공과 다릅니다. Graylog Search → Alerts → n8n Executions → Discord 순으로 확인하세요.
5. K09 숫자 Range 쿼리는 필드가 숫자로 색인되어야 동작합니다.
6. ED-WZ-02는 현재 `group_by`가 없고 Rule ID들에 동일 Notification이 적용됩니다. 생성 이벤트가 원본 개별 Rule ID 필드를 자동 전달하지 않을 수 있습니다.
7. 기존 ED-05는 서로 다른 rule 조합을 요구하므로 EX-01 포트 스캔 단독 모의 로그는 ED-05를 발동시키지 않습니다.

## 테스트 건수
- `K09-01_다중포트접근.txt`: 1건
- `K09-02_TCP_SYN급증.txt`: 1건
- `K09-03_IP별패킷과다.txt`: 1건
- `EX-01_단독포트스캔.txt`: 3건
- `EX-02_SYN_Flood탐지.txt`: 10건
- `EX-03_LowAndSlow_비활성.txt`: 8건
- `EX-04_심야로그인.txt`: 1건
- `EX-05_SQLInjection.txt`: 1건
- `EX-06_내부비인가접근.txt`: 1건
- `EX-07_로그변조_비활성.txt`: 1건
- `EX-08_Nikto스캐너.txt`: 1건
- `WZ-100230_Linux보안로그변경.txt`: 1건
- `WZ-100231_SSH및감사설정변경.txt`: 1건
- `WZ-100232_sudo특권명령.txt`: 1건
- `WZ-100233_Linux사용자그룹변경.txt`: 1건
- `WZ-100234_rootSSH로그인성공.txt`: 1건
- `WZ-100235_허용되지않은SSH계정.txt`: 1건
- `WZ-100236_Flaskk3s설정변경.txt`: 1건
- `WZ-100237_Flaskk3s파일삭제.txt`: 1건

실제 Wazuh 이벤트 테스트는 `Wazuh_실제룰엔진_logtest_보조.txt`를 참조하세요.
