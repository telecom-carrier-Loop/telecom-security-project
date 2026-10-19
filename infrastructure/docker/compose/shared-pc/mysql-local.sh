#!/usr/bin/env bash
set -Eeuo pipefail
# Keep shell quoting inside Linux. Windows PowerShell 5.1 can strip nested
# quotes passed through docker exec sh -c. SQL arrives only through stdin.
export MYSQL_PWD="$(cat /run/secrets/root-password)"
exec mysql --protocol=socket -uroot --batch --skip-column-names "$@"
