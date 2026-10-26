"""Gunicorn 진입점: gunicorn --bind 0.0.0.0:5000 wsgi:app"""
from pathlib import Path
from dotenv import load_dotenv

# 컨테이너의 /app/.env를 읽고 기존 환경 변수보다 우선 적용
env_path = Path(__file__).resolve().parent / ".env"
load_dotenv(dotenv_path=env_path, override=True, encoding="utf-8-sig")

from app import create_app

app = create_app()