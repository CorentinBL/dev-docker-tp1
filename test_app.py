import pytest
from app import app

@pytest.fixture
def client_app():
    with app.test_client() as client:
        with app.app_context():
            yield client

def test_health(client_app):
    res = client_app.get("/health")
    assert res.status_code == 200

def test_hello(client_app):
    res = client_app.get("/hello")
    assert res.status_code == 200

@pytest.mark.integration
def test_dbtest(client_app):
    res = client_app.get("/dbtest")
    assert res.status_code == 200
    json_data = res.get_json()
    assert json_data.get("db_connection") == "successful"