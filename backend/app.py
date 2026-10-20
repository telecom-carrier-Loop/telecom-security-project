"""개발 서버 전용 실행 파일 (운영은 wsgi.py + gunicorn).

API_BIND_HOST: 기본 127.0.0.1 (내 PC에서만 접속).
  Docker 안의 n8n 이 host.docker.internal:5000 으로 웹 API 를 부르려면 0.0.0.0 으로 연다.
  이때 같은 네트워크의 다른 PC 에서도 접속할 수 있게 되므로 실습 중에만 사용한다.
"""
import os

from app import create_app

app = create_app()

if __name__ == "__main__":
    app.run(host=os.getenv("API_BIND_HOST", "127.0.0.1"), port=int(os.getenv("API_PORT", "5000")), debug=True)
