"""Gunicorn 진입점: gunicorn --bind 0.0.0.0:5000 wsgi:app"""
from pathlib import Path
from dotenv import load_dotenv

# backend/.env (이 파일 기준 같은 폴더)
load_dotenv(Path(__file__).resolve().parent / ".env")

from app import create_app

app = create_app()