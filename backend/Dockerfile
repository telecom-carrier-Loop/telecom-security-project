# Python 3.11 공식 슬림 이미지 사용
FROM python:3.11-slim

# 작업 디렉토리 설정
WORKDIR /app

# 시스템 빌드 의존성 설치 (MySQL 패키지 등에 필요)
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    default-libmysqlclient-dev \
    && rm -rf /var/lib/lists/*

# requirements.txt 복사 후 파이썬 패키지 설치
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# 현재 백엔드 폴더의 모든 소스 코드를 컨테이너 내부로 복사
COPY . .

# Flask API 서버 포트 개방
EXPOSE 5000

# 개발 서버 대신 Gunicorn WSGI 서버로 앱 실행 (app.py 안의 Flask 인스턴스가 app인 경우)
CMD ["gunicorn", "--bind", "0.0.0.0:5000", "wsgi:app"]