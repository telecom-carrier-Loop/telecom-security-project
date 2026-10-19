from tests.conftest import login


def test_requires_login(client):
    assert client.get("/api/dashboard/summary").status_code == 401


def test_returns_only_my_data_even_with_user_id_param(client):
    login(client, "alice@test.local")
    data = client.get("/api/dashboard/summary?user_id=2").json["data"]
    assert data["user"]["email"] == "alice@test.local"
    assert data["subscription"]["plan"]["name"] == "5G Basic"
    assert data["billing"]["amount_due"] == 35000
    assert data["membership"]["point_balance"] == 12000


def test_new_customer_empty_dashboard(client):
    client.post("/api/auth/register", json={"email": "fresh@test.local", "password": "abcd1234", "name": "신규"})
    login(client, "fresh@test.local", "abcd1234")
    data = client.get("/api/dashboard/summary").json["data"]
    assert data["subscription"] is None and data["usage"] is None and data["membership"] is None
    assert data["billing"]["amount_due"] == 0


def test_plans_sorted(client):
    fees = [p["monthly_fee"] for p in client.get("/api/plans").json["data"]["plans"]]
    assert fees == sorted(fees)
