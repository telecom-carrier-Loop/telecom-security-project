"""Synthetic local replication/restore lab; never targets host or production DBs."""
from pathlib import Path
import argparse
import json
import re
import secrets
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
COMPOSE = ROOT / "infrastructure/docker/compose/db-lab/compose.yaml"
SECRET_DIR = ROOT / ".secrets/db-lab"
SERVICES = {"mysql-primary", "mysql-replica", "mysql-restore"}
PROJECT = "telecom-b-db-lab-v1"


def redact(message):
    if SECRET_DIR.is_dir():
        for path in SECRET_DIR.iterdir():
            if path.is_file():
                value = path.read_text(encoding="ascii").strip()
                if value:
                    message = message.replace(value, "<redacted>")
    return message


def run(args, *, data=None, timeout=180):
    result = subprocess.run(args, input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            cwd=ROOT, timeout=timeout)
    if result.returncode:
        # Credentials are supplied through stdin/mounted files, never CLI arguments.
        raise RuntimeError(redact(result.stderr.decode("utf-8", errors="replace")[-2500:]))
    return result.stdout


def compose(*args, data=None, timeout=180):
    return run(["docker", "compose", "-p", PROJECT, "-f", str(COMPOSE), *args], data=data, timeout=timeout)


def sql(service, query, *, app=False, expect_failure=False):
    if service not in SERVICES:
        raise ValueError("Only this lab's named Compose services may be used")
    secret = "app-password" if app else "root-password"
    user = "telecom_app" if app else "root"
    command = f'MYSQL_PWD="$(cat /run/secrets/{secret})" exec mysql --protocol=socket -u{user} --batch --skip-column-names'
    args = ["docker", "compose", "-p", PROJECT, "-f", str(COMPOSE), "exec", "-T", service, "sh", "-c", command]
    result = subprocess.run(args, input=query.encode() + b"\n", stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, cwd=ROOT, timeout=40)
    if expect_failure:
        if result.returncode == 0 or b"ERROR 1290" not in result.stderr:
            raise RuntimeError("Replica app write was not rejected by read-only protection")
        return "rejected"
    if result.returncode:
        raise RuntimeError(redact(result.stderr.decode("utf-8", errors="replace")[-2000:]))
    return result.stdout.decode().strip()


def prepare():
    SECRET_DIR.mkdir(parents=True, exist_ok=True)
    for name in ("primary-root", "replica-root", "restore-root", "app-password", "replication-password-v1"):
        path = SECRET_DIR / name
        if not path.exists():
            with path.open("x", encoding="ascii") as stream:
                stream.write(secrets.token_hex(16 if name == "replication-password-v1" else 24))
            path.chmod(0o600)
    print("Ignored lab secrets prepared; values hidden.")


def wait_ready(service):
    for _ in range(60):
        try:
            if sql(service, "SELECT 1;") == "1":
                return
        except (RuntimeError, subprocess.TimeoutExpired):
            time.sleep(2)
    raise RuntimeError(f"{service} did not become ready. Inspect its local Docker logs.")


def initialize():
    prepare()
    compose("up", "--build", "-d", "mysql-primary", "mysql-replica", timeout=600)
    wait_ready("mysql-primary")
    wait_ready("mysql-replica")
    if sql("mysql-replica", "SHOW REPLICA STATUS;"):
        print("Existing replication configuration preserved; run verify next.")
        return
    for service in ("mysql-primary", "mysql-replica"):
        count = sql(service, "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='telecom';")
        if count != "0":
            raise RuntimeError("Initial replication requires empty synthetic telecom databases. No reset/drop performed.")
    password = (SECRET_DIR / "replication-password-v1").read_text(encoding="ascii")
    if len(password) != 32 or any(c not in "0123456789abcdef" for c in password):
        raise RuntimeError("Unexpected lab credential format")
    sql("mysql-primary", f"CREATE USER IF NOT EXISTS 'telecom_repl'@'%' IDENTIFIED BY '{password}' REQUIRE SSL; GRANT REPLICATION SLAVE ON *.* TO 'telecom_repl'@'%';")
    sql("mysql-replica", f"CHANGE REPLICATION SOURCE TO SOURCE_HOST='mysql-primary', SOURCE_USER='telecom_repl', SOURCE_PASSWORD='{password}', SOURCE_AUTO_POSITION=1, SOURCE_SSL=1; START REPLICA; SET PERSIST read_only=ON; SET PERSIST super_read_only=ON;")
    print("GTID replication initialized. Lab TLS is encrypted but does not verify server identity; production requires verified TLS.")


def verify():
    marker = str(uuid.uuid4())
    sql("mysql-primary", "CREATE TABLE IF NOT EXISTS telecom.infra_probe (id VARCHAR(36) PRIMARY KEY, payload VARCHAR(128) NOT NULL) ENGINE=InnoDB;")
    sql("mysql-primary", f"INSERT INTO telecom.infra_probe VALUES ('{marker}', 'synthetic-b-test');")
    executed = sql("mysql-primary", "SELECT @@GLOBAL.gtid_executed;")
    if sql("mysql-replica", f"SELECT WAIT_FOR_EXECUTED_GTID_SET('{executed}', 20);") != "0":
        raise RuntimeError("Replica failed to apply source GTIDs within 20 seconds")
    if sql("mysql-replica", f"SELECT payload FROM telecom.infra_probe WHERE id='{marker}';") != "synthetic-b-test":
        raise RuntimeError("Replicated synthetic record differs")
    if sql("mysql-replica", "SELECT @@read_only, @@super_read_only;") != "1\t1":
        raise RuntimeError("Replica is not protected")
    sql("mysql-replica", f"INSERT INTO telecom.infra_probe VALUES ('{uuid.uuid4()}', 'must-fail');", app=True, expect_failure=True)
    receiver = sql("mysql-replica", "SELECT SERVICE_STATE FROM performance_schema.replication_connection_status;")
    applier = sql("mysql-replica", "SELECT SERVICE_STATE FROM performance_schema.replication_applier_status;")
    if receiver != "ON" or applier != "ON":
        raise RuntimeError("Replication receiver/applier is not running")
    print(json.dumps({"test": "B-DB-REPLICATION", "status": "PASS", "marker": marker,
                      "gtid_applied": True, "replica_write_rejected": True}, ensure_ascii=False))


def status():
    for service in ("mysql-primary", "mysql-replica"):
        print(service, sql(service, "SELECT @@server_id, @@gtid_mode, @@read_only, @@super_read_only;"))
    print("receiver state/error:", sql("mysql-replica", "SELECT SERVICE_STATE,LAST_ERROR_NUMBER FROM performance_schema.replication_connection_status;"))
    print("applier state:", sql("mysql-replica", "SELECT SERVICE_STATE FROM performance_schema.replication_applier_status;"))
    # Full replication errors can include CREATE USER password hashes: omit SQL text.
    print("worker state/error:", sql("mysql-replica", "SELECT SERVICE_STATE,LAST_ERROR_NUMBER FROM performance_schema.replication_applier_status_by_worker;"))


def restore_test():
    prepare()
    wait_ready("mysql-primary")
    compose("--profile", "restore", "up", "-d", "mysql-restore", timeout=600)
    wait_ready("mysql-restore")
    if sql("mysql-restore", "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='telecom_restore_test';") != "0":
        raise RuntimeError("Restore target is not empty. Nothing dropped/overwritten; use a new isolated lab for another restore test.")
    command = 'MYSQL_PWD="$(cat /run/secrets/root-password)" exec mysqldump --protocol=socket -uroot --single-transaction --no-tablespaces --set-gtid-purged=OFF --routines --events --triggers --hex-blob telecom'
    dump = compose("exec", "-T", "mysql-primary", "sh", "-c", command)
    if not dump or b"CREATE DATABASE" in dump or b"USE `telecom`" in dump:
        raise RuntimeError("Unsafe/empty restore dump")
    directory = ROOT / ".data/db-lab-backups"
    directory.mkdir(parents=True, exist_ok=True)
    backup_path = directory / f"synthetic-{time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())}.sql"
    with backup_path.open("xb") as stream:
        stream.write(dump)
    restore_command = 'MYSQL_PWD="$(cat /run/secrets/root-password)" exec mysql --protocol=socket -uroot telecom_restore_test'
    compose("exec", "-T", "mysql-restore", "sh", "-c", restore_command, data=dump)
    expected = sql("mysql-primary", "SELECT COUNT(*) FROM telecom.infra_probe;")
    actual = sql("mysql-restore", "SELECT COUNT(*) FROM telecom_restore_test.infra_probe;")
    if expected != actual:
        raise RuntimeError("Restored synthetic row count differs")
    print(json.dumps({"test": "B-DB-RESTORE", "status": "PASS", "rows": int(actual),
                      "target": "separate mysql-restore container / telecom_restore_test",
                      "note": "Synthetic local dump only; production GPG encryption not exercised"}, ensure_ascii=False))


def main():
    global PROJECT
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["prepare", "init", "verify", "status", "restore-test", "down"])
    parser.add_argument("--project", default=PROJECT)
    args = parser.parse_args()
    if not re.fullmatch(r"telecom-b-db-lab-[a-z0-9-]+", args.project):
        raise SystemExit("Only telecom-b-db-lab-* project names are allowed")
    PROJECT = args.project
    if args.action == "down":
        compose("--profile", "restore", "down")
        print("Lab containers stopped; named volumes and backups preserved.")
    else:
        {"prepare": prepare, "init": initialize, "verify": verify, "status": status, "restore-test": restore_test}[args.action]()


if __name__ == "__main__":
    main()
