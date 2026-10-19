# 표준 이벤트 — D / A·인프라 담당·C

필수: schema_version, source, event_id, event_type, detected_at, severity, title, asset. 시간은 UTC ISO8601, severity는 info/low/medium/high/critical입니다. received_at은 수신기가 추가하고 request_id/scenario_id/evidence는 해당 시 사용합니다.

```json
{
  "schema_version": "1.0",
  "source": "suricata",
  "event_id": "sensor-c-01:lab-0001",
  "event_type": "ids.suricata.alert",
  "detected_at": "2026-10-18T04:00:00Z",
  "severity": "medium",
  "title": "합성 IDS 탐지",
  "asset": {"host": "pc1", "service": "telecom-api"},
  "scenario_id": "IDS-01",
  "request_id": "req-lab-0001",
  "evidence": {"signature_id": 1000001}
}
```

원본 timestamp는 detected_at으로 정규화합니다. Wazuh/Graylog를 경유해도 source/event_id를 바꾸지 않고 collector를 별도 기록합니다. (source,event_id)로 원본 중복을 제거하고 사건 상관 분석은 별개로 취급합니다.

severity 매핑: Wazuh0~3 info/4~6 low/7~9 medium/10~12 high/13~15 critical. Suricata1 high/2 medium/3 low/그 외 info+원본 보존. Zabbix0 info/1 low/2 medium/3~4 high/5 critical.

이벤트명과 재시도·영속 저장·티켓 계약은 [통합 기준](../integration-baseline-v1.0.md)의 12~13절을 따릅니다. 현재 JSON Schema 검증기와 재처리 서비스는 구현되지 않았습니다.
