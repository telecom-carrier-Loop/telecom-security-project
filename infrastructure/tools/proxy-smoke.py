"""Test local TLS/reverse-proxy boundaries using disposable Nginx fixtures, not A's app."""
from pathlib import Path
import http.client
import json
import socket
import ssl
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
IMAGE = "nginx:1.28-alpine@sha256:a8b39bd9cf0f83869a2162827a0caf6137ddf759d50a171451b335cecc87d236"
prefix = f"telecom-b-proxy-{uuid.uuid4().hex[:8]}"
containers = []
network_id = None


def run(*args):
    result = subprocess.run(["docker", *args], cwd=ROOT, capture_output=True, timeout=180)
    if result.returncode:
        raise RuntimeError(result.stderr.decode(errors="replace")[-2000:])
    return result.stdout.decode().strip()


def mount(source, target):
    return ["--mount", f"type=bind,src={source},dst={target},readonly"]


def container(name, options):
    identity = run("create", "--name", f"{prefix}-{name}", "--network", network_id,
                   "--network-alias", name, *options, IMAGE)
    containers.append(identity)
    run("start", identity)


def main():
    global network_id
    tls = ROOT / ".secrets/tls"
    if not all((tls / name).exists() for name in ("ca.crt", "server.crt", "server.key")):
        raise SystemExit("Run prepare-local.py first")
    for port in (18088, 18443):
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", port))
    directory = ROOT / ".data/proxy-smoke"
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "api.conf").write_text('''server {
      listen 5000; default_type application/json;
      add_header X-Fixture-Forwarded-For $http_x_forwarded_for always;
      add_header X-Fixture-Proto $http_x_forwarded_proto always;
      add_header X-Fixture-Request-ID $http_x_request_id always;
      location / { return 200 '{"success":true,"data":{"status":"fixture"}}'; }
    }\n''', encoding="utf-8")
    (directory / "web.conf").write_text('''server {
      listen 80; root /usr/share/nginx/html;
      location / { try_files $uri $uri/ /index.html; }
    }\n''', encoding="utf-8")
    (directory / "index.html").write_text("<h1>B fixture SPA</h1>\n", encoding="utf-8")
    context = ssl.create_default_context(cafile=str(tls / "ca.crt"))
    tests = []

    def request(path, *, tls_enabled=True, headers=None):
        if tls_enabled:
            connection = http.client.HTTPSConnection("127.0.0.1", 18443, context=context, timeout=3)
        else:
            connection = http.client.HTTPConnection("127.0.0.1", 18088, timeout=3)
        try:
            connection.request("GET", path, headers={"Host": "portal.telecom.test", **(headers or {})})
            response = connection.getresponse()
            return response.status, dict((k.lower(), v) for k, v in response.getheaders()), response.read()
        finally:
            connection.close()

    try:
        network_id = run("network", "create", prefix)
        container("api", mount(directory / "api.conf", "/etc/nginx/conf.d/default.conf"))
        container("web", mount(directory / "web.conf", "/etc/nginx/conf.d/default.conf")
                  + mount(directory / "index.html", "/usr/share/nginx/html/index.html"))
        container("edge", ["-p", "127.0.0.1:18088:80", "-p", "127.0.0.1:18443:443"]
                  + mount(ROOT / "infrastructure/docker/compose/local/nginx.conf", "/etc/nginx/conf.d/default.conf")
                  + mount(tls / "server.crt", "/etc/nginx/tls/server.crt")
                  + mount(tls / "server.key", "/etc/nginx/tls/server.key"))
        for _ in range(30):
            try:
                if request("/")[0] == 200:
                    break
            except (OSError, http.client.HTTPException):
                time.sleep(1)
        status, headers, _ = request("/", tls_enabled=False)
        assert status == 308 and headers["location"].startswith("https://portal.telecom.test:8443/")
        tests.append("HTTP redirects to HTTPS")
        assert b"B fixture SPA" in request("/dashboard")[2]
        tests.append("SPA direct path")
        status, headers, body = request("/api/health/live", headers={"X-Forwarded-For": "spoofed", "X-Forwarded-Proto": "http", "X-Request-ID": "spoofed"})
        assert status == 200 and json.loads(body)["success"]
        assert headers["x-fixture-proto"] == "https"
        assert headers["x-fixture-forwarded-for"] != "spoofed"
        assert headers["x-fixture-request-id"] == headers["x-request-id"] != "spoofed"
        tests.append("API routing and trusted proxy/request headers")
        for path in ("/admin", "/admin/x", "/api/admin", "/api/admin/incidents",
                     "/api/internal", "/api/internal/incident-events", "/api/%61dmin/incidents",
                     "//api/admin/incidents", "/api/x/../admin/incidents"):
            assert request(path)[0] == 404, f"Public boundary bypass: {path}"
        tests.append("public admin/internal paths blocked, including normalized paths")
        print(json.dumps({"test": "B-TLS-PROXY", "status": "PASS", "checks": tests,
                          "scope": "disposable fixtures; actual A app not tested"}, ensure_ascii=False))
    finally:
        # Only resources created and recorded by this invocation are removed.
        for identity in reversed(containers):
            subprocess.run(["docker", "rm", "-f", identity], capture_output=True, timeout=30)
        if network_id:
            subprocess.run(["docker", "network", "rm", network_id], capture_output=True, timeout=30)


if __name__ == "__main__":
    main()
