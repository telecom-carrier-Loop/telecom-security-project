# syntax=docker/dockerfile:1
# The build context is the repository root, unlike the normal API image.
ARG PYTHON_IMAGE=python:3.12-slim-bookworm
FROM ${PYTHON_IMAGE}
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /workspace
RUN groupadd --gid 10001 app && useradd --uid 10001 --gid app --no-create-home app
COPY backend/requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY --chown=app:app backend/ ./backend/
COPY --chown=app:app database/migrations/ ./database/migrations/
WORKDIR /workspace/backend
USER 10001:10001
# A must initialize this directory and Flask-Migrate integration first.
CMD ["flask", "--app", "wsgi:app", "db", "upgrade", "--directory", "../database/migrations"]
