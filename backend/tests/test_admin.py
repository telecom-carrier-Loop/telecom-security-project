from tests.conftest import login


def test_customer_cannot_open_admin_dashboard(client):
    login(client, "alice@test.local")
    assert client.get("/api/admin/dashboard").status_code == 403


def test_admin_dashboard_counts(client):
    login(client, "alice@test.local", "wrong-pass1")
    login(client, "support@test.local")
    data = client.get("/api/admin/dashboard").json["data"]
    assert data["customers"]["active"] == 2 and data["customers"]["login_failures_15m"] == 1
    assert data["support"]["waiting"] == 1
    assert data["billing"] == {"unpaid_count": 2, "unpaid_amount": 90000}
    assert data["incidents"]["open"] == 2 and data["incidents"]["by_severity"]["high"] == 1
    assert "@test.local" not in str(data)
