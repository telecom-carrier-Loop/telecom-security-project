#!/usr/bin/env bash
set -euo pipefail
# Checks the local edge only. Do not make shared DB readiness a VIP election input.
curl --fail --silent --show-error --max-time 2 \
    http://127.0.0.1:18080/edge-health >/dev/null
