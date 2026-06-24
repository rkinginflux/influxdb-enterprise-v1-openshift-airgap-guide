# InfluxDB Enterprise v1 on OpenShift (Air-Gapped) - Installation Guide

This guide explains how to install the InfluxData Helm chart `influxdb-enterprise` (v0.2.1) for InfluxDB Enterprise v1 in an air-gapped OpenShift environment.

Repository source chart:
- https://github.com/influxdata/helm-charts/tree/master/charts/influxdb-enterprise

## Scope and assumptions

- Target platform: OpenShift (customer cluster), air-gapped.
- Installation client may be a separate machine with `oc` + `helm` access to the cluster API.
- The cluster can pull only from an internal registry.
- InfluxDB Enterprise license file is provided by InfluxData.

## Important chart defaults to account for

From the chart templates/values:
- Chart version: `0.2.1`
- App version: `1.12.3`
- Default images resolve to:
  - `influxdb:1.12.3-meta`
  - `influxdb:1.12.3-data`
- TLS + cert-manager are enabled by default in values (`meta/data.https.useCertManager: true`).
- Persistence is disabled by default.
- Bootstrap Job is a `post-install` hook and runs once on install (not on upgrade).

## Air-gap workflow overview

There are two zones:
1. Connected zone (internet access): collect artifacts and mirror images.
2. Air-gapped zone: import artifacts into internal registry and install.

---

## 1) Connected zone: prepare artifacts

### 1.1 Pull chart package

```bash
helm repo add influxdata https://helm.influxdata.com
helm repo update
helm pull influxdata/influxdb-enterprise --version 0.2.1
```

Produces:
- `influxdb-enterprise-0.2.1.tgz`

### 1.2 Mirror required images to internal registry

Required tags:
- `docker.io/library/influxdb:1.12.3-meta`
- `docker.io/library/influxdb:1.12.3-data`

Example with skopeo:

```bash
skopeo copy docker://docker.io/library/influxdb:1.12.3-meta docker://<internal-registry>/influxdb/influxdb:1.12.3-meta
skopeo copy docker://docker.io/library/influxdb:1.12.3-data docker://<internal-registry>/influxdb/influxdb:1.12.3-data
```

### 1.3 Transfer artifacts into restricted zone

Transfer using approved process:
- chart package (`influxdb-enterprise-0.2.1.tgz`)
- license file from InfluxData (`license.json`)
- this guide and values file template

---

## 2) Air-gapped zone: cluster install

### 2.1 Prerequisites

- Logged into OpenShift cluster:
  - `oc whoami`
  - `oc get nodes`
- Helm installed and usable
- Internal registry reachable from cluster nodes

### 2.2 Create namespace

```bash
oc new-project influxdb-enterprise
```

### 2.3 Create required secrets

#### License secret (required)

```bash
oc -n influxdb-enterprise create secret generic influxdb-license \
  --from-file=json=./license.json
```

#### Shared secret for meta/data internal auth (required)

```bash
oc -n influxdb-enterprise create secret generic influxdb-shared-secret \
  --from-literal=secret="$(openssl rand -base64 48 | tr -d '\n')"
```

#### Bootstrap auth secret (optional, recommended)

```bash
oc -n influxdb-enterprise create secret generic influxdb-auth \
  --from-literal=username=admin \
  --from-literal=password='CHANGE_ME_TO_STRONG_PASSWORD'
```

### 2.4 Create values file

Use `examples/values-airgap.yaml` with your environment-specific substitutions (`<internal-registry>`, `<storageclass>`):

```yaml
serviceAccount:
  create: true
  name: influxdb-enterprise

license:
  secret:
    name: influxdb-license
    key: json

livenessProbe:
  initialDelaySeconds: 3600

bootstrap:
  auth:
    secretName: influxdb-auth

meta:
  replicas: 3
  image:
    repository: <internal-registry>/influxdb/influxdb
  sharedSecret:
    secretName: influxdb-shared-secret
  persistence:
    enabled: true
    storageClass: <storageclass>
    accessMode: ReadWriteOnce
    size: 20Gi
  https:
    enabled: false
    useCertManager: false

data:
  replicas: 3
  image:
    repository: <internal-registry>/influxdb/influxdb
  persistence:
    enabled: true
    storageClass: <storageclass>
    accessMode: ReadWriteOnce
    size: 100Gi
  https:
    enabled: false
    useCertManager: false
  flux:
    enabled: true
```

### 2.5 Install from local chart package

```bash
helm upgrade --install influxdb-enterprise ./influxdb-enterprise-0.2.1.tgz \
  -n influxdb-enterprise \
  -f ./examples/values-airgap.yaml
```

---

## 3) Verification

```bash
oc -n influxdb-enterprise get pods,svc,pvc
oc -n influxdb-enterprise get statefulset
```

Check logs:

```bash
oc -n influxdb-enterprise logs statefulset/influxdb-enterprise-influxdb-enterprise-meta --tail=200
oc -n influxdb-enterprise logs statefulset/influxdb-enterprise-influxdb-enterprise-data --tail=200
```

Verify cluster from a meta pod:

```bash
oc -n influxdb-enterprise exec -it influxdb-enterprise-influxdb-enterprise-meta-0 -- influxd-ctl show
```

---

## 4) OpenShift SCC considerations

Try default SCC first.

If pods fail with UID/permission errors, grant `anyuid` to the chart SA:

```bash
oc adm policy add-scc-to-user anyuid -z influxdb-enterprise -n influxdb-enterprise
```

Then restart StatefulSets:

```bash
oc -n influxdb-enterprise rollout restart statefulset/influxdb-enterprise-influxdb-enterprise-meta
oc -n influxdb-enterprise rollout restart statefulset/influxdb-enterprise-influxdb-enterprise-data
```

---

## 5) License rotation / renewal in air gap

Replace secret with new license file:

```bash
oc -n influxdb-enterprise delete secret influxdb-license
oc -n influxdb-enterprise create secret generic influxdb-license \
  --from-file=json=./new-license.json
```

Restart pods to ensure license reload:

```bash
oc -n influxdb-enterprise rollout restart statefulset/influxdb-enterprise-influxdb-enterprise-meta
oc -n influxdb-enterprise rollout restart statefulset/influxdb-enterprise-influxdb-enterprise-data
```

---

## 6) Troubleshooting quick checks

### `cert-manager` CRD errors during install
Set in values:
- `meta.https.useCertManager: false`
- `data.https.useCertManager: false`

### ImagePullBackOff
- Validate internal image paths and tags
- Confirm pull permissions from node/namespace to internal registry

### Pending PVCs
- Verify storage class exists and supports requested access mode/size

### Bootstrap did not rerun after Helm upgrade
- Expected behavior: bootstrap is post-install only
- Run required auth/DDL/DML tasks manually if needed after upgrade

---

## 7) Security notes

- Prefer license via secret-mounted file (`license.secret`) over inline `license.key`.
- Keep `license.json` out of git repositories.
- Use strong credentials for bootstrap auth.
- Enable TLS with internal PKI as a follow-up hardening step if not enabled initially.

---

## Appendix: chart references used in this guide

Checked from chart source:
- `Chart.yaml` (version/appVersion)
- `values.yaml` (defaults for TLS/cert-manager, persistence)
- `templates/meta-statefulset.yaml`
- `templates/data-statefulset.yaml`
- `templates/bootstrap-job.yaml`
- `README.md`
