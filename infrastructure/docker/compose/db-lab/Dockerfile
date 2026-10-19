# syntax=docker/dockerfile:1
ARG MYSQL_IMAGE=mysql:8.4@sha256:24989179f58856db763f418010c1169fecc944e3ec1ea7e921572d83eb070f70
FROM ${MYSQL_IMAGE}
ARG REPLICATION_ROLE
# Windows bind mounts may appear world-writable; MySQL ignores such .cnf files.
COPY --chmod=644 ${REPLICATION_ROLE}.cnf /etc/mysql/conf.d/replication.cnf
