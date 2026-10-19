# syntax=docker/dockerfile:1
FROM mysql:8.4@sha256:24989179f58856db763f418010c1169fecc944e3ec1ea7e921572d83eb070f70
ARG REPLICATION_ROLE
COPY --chmod=644 common.cnf /etc/mysql/conf.d/10-common.cnf
COPY --chmod=644 ${REPLICATION_ROLE}.cnf /etc/mysql/conf.d/20-role.cnf
COPY --chmod=755 start-mysql.sh /usr/local/bin/start-shared-mysql
ENTRYPOINT ["/usr/local/bin/start-shared-mysql"]
CMD ["mysqld"]
