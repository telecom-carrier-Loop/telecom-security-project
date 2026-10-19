from tests.conftest import login


def test_customer_cannot_open_admin_dashboard(client):
    login(client, "alice@test.local")
    assert client.get("/api/admin/dashboard").status_code == 403


def test_admin_dashboard_counts(client):
    login(client, "alice@test.local", "wrong-pass1")
    login(client, "admin@test.local")
    data = client.get("/api/admin/dashboard").json["data"]
    assert data["customers"]["active"] == 2 and data["customers"]["login_failures_15m"] == 1
    assert data["support"]["waiting"] == 1
    assert data["billing"] == {"unpaid_count": 2, "unpaid_amount": 90000}
    assert data["incidents"]["open"] == 2 and data["incidents"]["by_severity"]["high"] == 1
    assert "@test.local" not in str(data)


def test_customer_list_is_admin_only_and_masked(client):
    from tests.conftest import logout
    login(client, "alice@test.local")
    assert client.get("/api/admin/customers").status_code == 403
    logout(client)
    login(client, "admin@test.local")
    data = client.get("/api/admin/customers").json["data"]
    assert data["total"] == 2
    alice = next(c for c in data["customers"] if c["name"] == "김하늘")
    assert alice["email"] == "al***@test.local" and alice["plan"] == "5G Basic" and alice["unpaid_amount"] == 35000
    assert client.get("/api/admin/customers?q=이바다").json["data"]["total"] == 1


def test_customer_detail_shows_full_info(client):
    login(client, "admin@test.local")
    d = client.get("/api/admin/customers/1").json["data"]["customer"]
    assert d["email"] == "alice@test.local" and d["membership"]["point_balance"] == 12000
    assert len(d["tickets"]) == 1 and len(d["invoices"]) == 2
    assert client.get("/api/admin/customers/3").status_code == 404  # 관리자 계정은 회원 목록 대상 아님


def test_seed_has_single_admin_role(app):
    from app.models import User
    roles = {u.role for u in User.query.all()}
    assert roles == {"CUSTOMER", "ADMIN"}


def test_admin_can_do_support_and_security_work(client):
    """통합 관리자 하나로 문의·결제·혜택·인시던트 화면 API를 모두 쓸 수 있다."""
    login(client, "admin@test.local")
    for path in ("/api/admin/support", "/api/admin/payments", "/api/admin/membership/benefits",
                 "/api/admin/incidents", "/api/admin/customers", "/api/admin/monitoring-links"):
        assert client.get(path).status_code == 200, path


def test_monitoring_links(client, monkeypatch):
    login(client, "alice@test.local")
    assert client.get("/api/admin/monitoring-links").status_code == 403
    from tests.conftest import logout
    logout(client)
    login(client, "admin@test.local")
    links = {l["key"]: l for l in client.get("/api/admin/monitoring-links").json["data"]["links"]}
    assert links["wazuh"]["url"] == "https://localhost" and links["graylog"]["url"] == "http://localhost:9000"
    monkeypatch.setenv("GRAYLOG_URL", "javascript:alert(1)")  # 이상한 주소는 쓰지 않음
    monkeypatch.setenv("WAZUH_DASHBOARD_URL", "https://manage2.telecom.test/wazuh/")
    links = {l["key"]: l for l in client.get("/api/admin/monitoring-links").json["data"]["links"]}
    assert links["wazuh"]["url"] == "https://manage2.telecom.test/wazuh/"
    assert links["graylog"]["url"] == "http://localhost:9000"
