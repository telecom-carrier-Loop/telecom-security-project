"""Render host-specific examples into ignored .data; never modify system config."""
from pathlib import Path
import argparse

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument("host", choices=["pc1", "pc2"])
args = parser.parse_args()
suffix = "11" if args.host == "pc1" else "12"
source = ROOT / "infrastructure/nginx/host-nginx.conf.example"
text = source.read_text(encoding="utf-8").replace("__WAS_IP__", f"192.168.20.{suffix}")
text = text.replace("__MGMT_IP__", f"192.168.50.{suffix}")
target = ROOT / ".data/rendered" / args.host / "nginx.conf"
target.parent.mkdir(parents=True, exist_ok=True)
target.write_text(text, encoding="utf-8", newline="\n")
print(f"Rendered ignored .data/rendered/{args.host}/nginx.conf; no host settings changed.")
