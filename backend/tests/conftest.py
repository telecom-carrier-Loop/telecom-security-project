import pytest
from flask.testing import FlaskClient

from app import create_app
from app.cli import load_seed_module
from app.config import TestConfig
from app.extensions import db

SEED = None


@pytest.fixture()
def app():
    global SEED
    app = create_app(TestConfig)
    with app.app_context():
        db.create_all()
        SEED = load_seed_module()
        SEED.seed_data()
        yield app
        db.session.remove()
        db.drop_all()


HOST = "portal.telecom.test"


class HttpsClient(FlaskClient):
    """__Host- 쿠키는 Secure 이므로 HTTPS 주소로 시험한다 (로컬 Compose도 HTTPS 8443)."""

    csrf_token = None

    def open(self, *args, **kwargs):
        kwargs.setdefault("base_url", f"https://{HOST}")
        return super().open(*args, **kwargs)


def new_client(app):
    app.test_client_class = HttpsClient
    return app.test_client()


@pytest.fixture()
def client(app):
    return new_client(app)


def login(client, email, password="Test1234!"):
    res = client.post("/api/auth/login", json={"email": email, "password": password})
    client.csrf_token = res.json["data"]["csrf_token"] if res.status_code == 200 else None
    return res


def csrf(client, **extra):
    return {"X-CSRF-Token": client.csrf_token or "", **extra}


def logout(client):
    client.post("/api/auth/logout", headers=csrf(client))
    client.csrf_token = None
