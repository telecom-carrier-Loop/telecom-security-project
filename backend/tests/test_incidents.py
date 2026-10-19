import copy

from tests.conftest import csrf, login, logout

TOKEN = {"Authorization": "Bearer test-incident-token"}
EVENT = {
    "schema_version": "1.0", "source": "suricata", "event_id": "sensor-c-01:lab-0001",
    "event_type": "ids.suricata.alert", "detected_at": "2026-10-18T04:00:00Z", "severity": "medium",
    "title": "실습 IDS 탐지", "asset": {"host": "pc1", "service": "telecom-api"},
    "scenario_id": "IDS-01", "request_id": "req-lab-0001", "evidence": {"signature_id": 1000001},
}
URL = "/api/internal/incident-events"


def test_token_required(client):
    assert client.post(URL, json=EVENT).status_code == 401
    assert client.post(URL, json=EVENT, headers={"Authorization": "Bearer wrong"}).status_code == 401


def test_admin_session_cannot_use_internal_api(client):
    login(client, "security@test.local")
    assert client.post(URL, json=EVENT, headers=csrf(client)).status_code == 401


def test_token_cannot_use_admin_api(client):
    assert client.get("/api/admin/incidents", headers=TOKEN).status_code == 401


def test_same_event_three_times_one_ticket(client):
    first = client.post(URL, json=EVENT, headers=TOKEN)
    assert first.status_code == 201 and first.json["data"]["deduplicated"] is False
    for _ in range(2):
        again = client.post(URL, json=EVENT, headers=TOKEN)
        assert again.status_code == 200 and again.json["data"]["deduplicated"] is True
        assert again.json["data"]["incident_id"] == first.json["data"]["incident_id"]


def test_collector_metadata_does_not_change_hash(client):
    client.post(URL, json=EVENT, headers=TOKEN)
    via_graylog = {**EVENT, "collector": "graylog", "received_at": "2026-10-18T04:00:05Z",
                   "detected_at": "2026-10-18T04:00:00+00:00"}
    assert client.post(URL, json=via_graylog, headers=TOKEN).status_code == 200


def test_same_key_different_content_409(client):
    client.post(URL, json=EVENT, headers=TOKEN)
    changed = {**EVENT, "severity": "high"}
    assert client.post(URL, json=changed, headers=TOKEN).status_code == 409


def test_invalid_event_422(client):
    bad = copy.deepcopy(EVENT)
    bad.update({"severity": "error", "detected_at": "2026-10-18 04:00"})
    del bad["asset"]
    res = client.post(URL, json=bad, headers=TOKEN)
    assert res.status_code == 422 and {"severity", "detected_at", "asset"} <= set(res.json["error"]["details"])


def test_only_security_admin(client):
    login(client, "support@test.local")
    assert client.get("/api/admin/incidents").status_code == 403
    logout(client)
    login(client, "alice@test.local")
    assert client.get("/api/admin/incidents").status_code == 403


def test_status_flow_and_history(client):
    inc_id = client.post(URL, json=EVENT, headers=TOKEN).json["data"]["incident_id"]
    login(client, "security@test.local")
    me = client.get("/api/admin/incidents/assignees").json["data"]["assignees"][0]
    data = client.patch(f"/api/admin/incidents/{inc_id}", json={"status": "INVESTIGATING", "assigned_to": me["id"]},
                        headers=csrf(client)).json["data"]["incident"]
    assert data["status"] == "INVESTIGATING" and data["assigned_to"]["id"] == me["id"]
    assert [h["action"] for h in data["histories"]] == ["CREATED", "STATUS_CHANGED", "ASSIGNED"]
    assert data["histories"][0]["actor"] == "자동 수신"
    assert client.patch(f"/api/admin/incidents/{inc_id}", json={"status": "CLOSED"}, headers=csrf(client)).status_code == 409
    for s in ("RESOLVED", "INVESTIGATING", "RESOLVED", "CLOSED"):  # 재개 포함
        assert client.patch(f"/api/admin/incidents/{inc_id}", json={"status": s}, headers=csrf(client)).status_code == 200
    note = client.post(f"/api/admin/incidents/{inc_id}/histories", json={"note": "C에게 출발지 차단 요청"}, headers=csrf(client))
    assert note.json["data"]["incident"]["histories"][-1]["note"] == "C에게 출발지 차단 요청"


def test_manual_create_and_assign_validation(client):
    login(client, "security@test.local")
    res = client.post("/api/admin/incidents", json={"title": "수동 보고", "severity": "low"}, headers=csrf(client))
    assert res.status_code == 201 and res.json["data"]["incident"]["source"] == "manual"
    assert client.patch("/api/admin/incidents/1", json={"assigned_to": 1}, headers=csrf(client)).status_code == 422
