"""Create ignored local credentials and TLS files; never overwrite existing files."""
from pathlib import Path
import os
import secrets
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def write_new(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("x", encoding="utf-8", newline="\n") as stream:
        stream.write(text)
    path.chmod(0o600)


def main():
    env_path = ROOT / ".env"
    if not env_path.exists():
        text = (ROOT / ".env.example").read_text(encoding="utf-8")
        values = {name: secrets.token_hex(24) for name in (
            "DB_PASSWORD", "MYSQL_ROOT_PASSWORD", "INCIDENT_API_TOKEN",
            "EVENT_INGEST_TOKEN", "N8N_ENCRYPTION_KEY",
        )}
        lines = []
        for line in text.splitlines():
            name = line.split("=", 1)[0]
            lines.append(f"{name}={values[name]}" if name in values else line)
        # Local-only DDL account, separate from the app runtime credential.
        lines += ["MIGRATION_DB_USER=root", f"MIGRATION_DB_PASSWORD={values['MYSQL_ROOT_PASSWORD']}"]
        write_new(env_path, "\n".join(lines) + "\n")
        print("Created ignored .env with independent random credentials (values hidden).")
    else:
        print("Existing .env preserved. Check migration variables before using the ops profile.")

    tls = ROOT / ".secrets" / "tls"
    if any((tls / name).exists() for name in ("ca.key", "ca.crt", "server.key", "server.crt")):
        if not all((tls / name).exists() for name in ("ca.key", "ca.crt", "server.key", "server.crt")):
            raise SystemExit("Partial TLS material exists; inspect it manually. Nothing overwritten.")
        print("Existing TLS material preserved.")
        return
    openssl = shutil.which("openssl")
    bundled = Path(r"C:\Program Files\Git\usr\bin\openssl.exe")
    if not openssl and bundled.exists():
        openssl = str(bundled)
    if not openssl:
        raise SystemExit("Install OpenSSL from a trusted source and rerun. .env remains preserved.")
    tls.mkdir(parents=True, exist_ok=True)
    environment = dict(os.environ, MSYS_NO_PATHCONV="1")

    def run(*args):
        subprocess.run([openssl, *args], check=True, cwd=tls, env=environment, capture_output=True)

    run("req", "-x509", "-newkey", "rsa:3072", "-nodes", "-days", "365", "-sha256",
        "-keyout", "ca.key", "-out", "ca.crt", "-subj", "/CN=Telecom Local Development CA",
        "-addext", "basicConstraints=critical,CA:TRUE", "-addext", "keyUsage=critical,keyCertSign,cRLSign")
    run("req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", "server.key",
        "-out", "server.csr", "-subj", "/CN=portal.telecom.test")
    write_new(tls / "server.ext", "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:portal.telecom.test,DNS:localhost,DNS:manage1.telecom.test,DNS:manage2.telecom.test,DNS:events.telecom.test,IP:127.0.0.1\n")
    run("x509", "-req", "-in", "server.csr", "-CA", "ca.crt", "-CAkey", "ca.key",
        "-CAcreateserial", "-out", "server.crt", "-days", "90", "-sha256", "-extfile", "server.ext")
    for name in ("ca.key", "server.key"):
        (tls / name).chmod(0o600)
    print("Created ignored TLS material. CA trust/hosts changes are manual; no system trust changed.")


if __name__ == "__main__":
    main()
