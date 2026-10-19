from tests.conftest import csrf, login, logout

NEW = {"category": "BILLING", "title": "요금 문의", "content": "청구 내역을 알고 싶어요."}


def test_create_and_list_only_mine(client):
    login(client, "bob@test.local")
    res = client.post("/api/support", json=NEW, headers=csrf(client))
    assert res.status_code == 201 and res.json["data"]["ticket"]["status"] == "OPEN"
    assert [t["title"] for t in client.get("/api/support").json["data"]["tickets"]] == ["요금 문의"]


def test_validation_422(client):
    login(client, "bob@test.local")
    res = client.post("/api/support", json={"category": "X", "title": "a", "content": ""}, headers=csrf(client))
    assert res.status_code == 422 and set(res.json["error"]["details"]) == {"category", "title", "content"}


def test_others_ticket_is_404(client):
    login(client, "bob@test.local")  # 1번 문의는 alice 것
    assert client.get("/api/support/1").status_code == 404
    assert client.patch("/api/support/1", json={"title": "탈취"}, headers=csrf(client)).status_code == 404
    assert client.post("/api/support/1/close", headers=csrf(client)).status_code == 404


def test_script_stored_as_text(client):
    login(client, "bob@test.local")
    payload = {**NEW, "content": "<script>alert(1)</script> 확인 부탁"}
    assert client.post("/api/support", json=payload, headers=csrf(client)).json["data"]["ticket"]["content"] == payload["content"]


def test_role_separation(client):
    login(client, "alice@test.local")
    assert client.post("/api/admin/support/1/replies", json={"content": "셀프"}, headers=csrf(client)).status_code == 403
    logout(client)
    login(client, "security@test.local")
    assert client.get("/api/admin/support").status_code == 403


def test_reply_flow_and_edit_lock(client):
    login(client, "support@test.local")
    res = client.post("/api/admin/support/1/replies", json={"content": "부가서비스 요금이 포함되었습니다."},
                      headers=csrf(client))
    assert res.status_code == 201 and res.json["data"]["ticket"]["status"] == "ANSWERED"
    logout(client)
    login(client, "alice@test.local")
    assert client.get("/api/support/1").json["data"]["ticket"]["replies"][0]["author"] == "상담원"
    assert client.patch("/api/support/1", json={"title": "수정"}, headers=csrf(client)).status_code == 409
    assert client.post("/api/support/1/close", headers=csrf(client)).json["data"]["ticket"]["status"] == "CLOSED"
