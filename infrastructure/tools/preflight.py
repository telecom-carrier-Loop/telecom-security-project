"""Read-only checks before attempting an A application image build."""
from pathlib import Path
import argparse
import json

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", action="store_true", help="Check A-owned application prerequisites")
    args = parser.parse_args()
    checks = ["infrastructure/docker/frontend/Dockerfile", "infrastructure/docker/backend/Dockerfile",
              "infrastructure/docker/compose/local/compose.yaml"]
    if args.app:
        checks += ["frontend/package.json", "frontend/package-lock.json", "backend/requirements.txt", "backend/wsgi.py"]
    missing = [name for name in checks if not (ROOT / name).is_file()]
    if missing:
        print("BLOCKED: prerequisites are missing; no application build was attempted.")
        for name in missing:
            print(f"  A/B handoff required: {name}")
        return 2
    if args.app:
        package = json.loads((ROOT / "frontend/package.json").read_text(encoding="utf-8"))
        if "build" not in package.get("scripts", {}):
            print("BLOCKED: frontend/package.json must define scripts.build")
            return 2
        requirements = (ROOT / "backend/requirements.txt").read_text(encoding="utf-8").lower()
        if "gunicorn" not in requirements:
            print("BLOCKED: confirm the Gunicorn dependency with A")
            return 2
    print("PASS: checked prerequisites. This is not a runtime/DB readiness test.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
