"""개발 서버 전용 실행 파일 (운영은 wsgi.py + gunicorn)"""
from app import create_app

app = create_app()

if __name__ == "__main__":
    app.run(host="127.0.0.1", port=5000, debug=True)
