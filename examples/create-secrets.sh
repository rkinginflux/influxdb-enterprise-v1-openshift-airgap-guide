#!/usr/bin/env bash
set -euo pipefail

NS=${1:-influxdb-enterprise}
LICENSE_PATH=${2:-./license.json}

oc get ns "$NS" >/dev/null 2>&1 || oc new-project "$NS"

oc -n "$NS" create secret generic influxdb-license \
  --from-file=json="$LICENSE_PATH" \
  --dry-run=client -o yaml | oc apply -f -

oc -n "$NS" create secret generic influxdb-shared-secret \
  --from-literal=secret="$(openssl rand -base64 48 | tr -d '\n')" \
  --dry-run=client -o yaml | oc apply -f -

echo "Created/updated secrets in namespace: $NS"
