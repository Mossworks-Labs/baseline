# Baseline Stack

Cluster-level infrastructure for TLS certificates and dynamic DNS, deployed as a single Helm umbrella chart.

## What It Does

| Component | Purpose |
|---|---|
| **cert-manager** (Jetstack v1.17.1) | Automates TLS certificate issuance and renewal via Let's Encrypt |
| **external-dns** (Bitnami v8.7.3) | Syncs Kubernetes Ingress hostnames to Cloudflare DNS records |
| **ClusterIssuer** | ACME issuer using DNS-01 challenge through Cloudflare |
| **Certificate** | Wildcard cert for `rudolphhome.com` + `*.rudolphhome.com` |

## Prerequisites

- K3s / Kubernetes cluster
- `helm` v3.x
- Cloudflare API token with the following permissions:
  - **Zone : DNS : Edit**
  - **Zone : Zone : Read**
- An ingress controller (e.g. `ingress-nginx`) already deployed

### Creating a Cloudflare API Token

1. Go to [Cloudflare Dashboard](https://dash.cloudflare.com/profile/api-tokens)
2. Click **Create Token**
3. Use the **Edit zone DNS** template
4. Under **Zone Resources**, select the target zone (`rudolphhome.com`)
5. Save the token — you'll need it for deployment

## Deployment

### 1. Pull chart dependencies

Only needed once, or after `Chart.yaml` changes:

```bash
helm dependency update .
```

### 2. Deploy the chart

Requires your Cloudflare account email and API token:

```bash
helm upgrade --install baseline . \
  --set cloudflare.email="you@example.com" \
  --set cloudflare.apiToken="<your-cf-token>" \
  --set external-dns.cloudflare.apiToken="<your-cf-token>"
```

> The Cloudflare token is passed twice because cert-manager and external-dns each manage their own Secret. This keeps the two subsystems independently configurable.

### 3. Post-deploy: clean up the craft chart

The craft Helm chart has its own embedded external-dns and cert-manager templates (`templates/dns/`, `templates/tls/`) that are currently disabled. Once baseline is deployed, these are redundant. Either:

- **Remove them** from the craft chart entirely, or
- **Leave them disabled** (no-op) — they won't conflict as long as their `enabled` flags stay `false`

### 4. Post-deploy: sync the backend lockfile

The craft backend's `axios` dependency was pinned to `1.13.6` to avoid a known issue in `1.14.1`. Run `npm install` in the backend directory to update the lockfile:

```bash
cd VideoIdeas/app/backend && npm install
```

## Verification

After deployment, confirm everything is healthy:

```bash
# cert-manager pods (controller, webhook, cainjector)
kubectl get pods -l app.kubernetes.io/instance=baseline -l app.kubernetes.io/name=cert-manager

# external-dns pod
kubectl get pods -l app.kubernetes.io/instance=baseline -l app.kubernetes.io/name=external-dns

# ClusterIssuer is ready
kubectl get clusterissuer letsencrypt-prod

# Certificate is issued
kubectl get certificate

# TLS secret exists
kubectl get secret baseline-tls
```

## Values Reference

### Top-Level

| Key | Default | Description |
|---|---|---|
| `domain` | `rudolphhome.com` | Base domain for the wildcard certificate |
| `cloudflare.email` | `""` | Cloudflare account email (used by cert-manager ACME) |
| `cloudflare.apiToken` | `""` | Cloudflare API token (used by cert-manager DNS-01 solver) |

### ClusterIssuer

| Key | Default | Description |
|---|---|---|
| `clusterIssuer.enabled` | `true` | Create the Let's Encrypt ClusterIssuer |
| `clusterIssuer.name` | `letsencrypt-prod` | Name of the ClusterIssuer resource |
| `clusterIssuer.server` | `https://acme-v02.api.letsencrypt.org/directory` | ACME server URL |

### Certificate

| Key | Default | Description |
|---|---|---|
| `certificate.enabled` | `true` | Create the wildcard Certificate resource |
| `certificate.secretName` | `baseline-tls` | Name of the TLS Secret that cert-manager populates |
| `certificate.extraDnsNames` | `["*.local.rudolphhome.com"]` | Additional SANs beyond the wildcard (for multi-level subdomains) |

### cert-manager (subchart)

| Key | Default | Description |
|---|---|---|
| `cert-manager.enabled` | `true` | Deploy cert-manager |
| `cert-manager.crds.enabled` | `true` | Install cert-manager CRDs |

Full subchart values: [cert-manager docs](https://artifacthub.io/packages/helm/cert-manager/cert-manager)

### external-dns (subchart — kubernetes-sigs/external-dns)

| Key | Default | Description |
|---|---|---|
| `external-dns.enabled` | `true` | Deploy external-dns |
| `external-dns.provider.name` | `cloudflare` | DNS provider |
| `external-dns.domainFilters` | `[rudolphhome.com]` | Limit which domains external-dns manages |
| `external-dns.policy` | `upsert-only` | Only create/update records, never delete |
| `external-dns.txtOwnerId` | `baseline` | TXT record owner ID for record ownership tracking |
| `external-dns.sources` | `[ingress]` | Kubernetes resource types to watch |

The Cloudflare API token is read from the `baseline-cloudflare` Secret (created by the chart) via the `CF_API_TOKEN` env var.

Full subchart values: [external-dns docs](https://github.com/kubernetes-sigs/external-dns/tree/master/charts/external-dns)

## How Other Stacks Consume This

Once baseline is deployed, any Ingress in the cluster can use TLS and automatic DNS by adding annotations:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  tls:
    - hosts:
        - myapp.rudolphhome.com
      secretName: myapp-tls          # cert-manager creates this
  rules:
    - host: myapp.rudolphhome.com    # external-dns creates the DNS record
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: my-app
                port:
                  number: 80
```

- **cert-manager** sees the `cert-manager.io/cluster-issuer` annotation and issues a cert into `myapp-tls`
- **external-dns** sees the Ingress hostname and creates an A record in Cloudflare pointing to the cluster's ingress IP

## Architecture

```
                          Cloudflare DNS
                         ┌─────────────┐
                         │ A  *.domain  │
                         │ TXT ownership│
                         └──────▲───▲──┘
                                │   │
                   DNS sync     │   │  DNS-01 challenge
                                │   │
                 ┌──────────────┘   └──────────────┐
                 │                                  │
          ┌──────┴──────┐                   ┌───────┴───────┐
          │ external-dns│                   │  cert-manager │
          │             │                   │  (controller) │
          └──────▲──────┘                   └───────▲───────┘
                 │ watches                          │ issues
                 │                                  │
          ┌──────┴──────┐                   ┌───────┴───────┐
          │   Ingress   │                   │ ClusterIssuer │
          │  resources  │                   │ letsencrypt-  │
          │             │                   │   prod        │
          └─────────────┘                   └───────────────┘
```

## Troubleshooting

### cert-manager not issuing certificates

```bash
# Check the Certificate status
kubectl describe certificate baseline-tls

# Check CertificateRequest and Order status
kubectl get certificaterequest
kubectl get order
kubectl get challenge

# Check cert-manager logs
kubectl logs -l app.kubernetes.io/name=cert-manager -l app.kubernetes.io/component=controller
```

### external-dns not creating DNS records

```bash
# Check external-dns logs
kubectl logs -l app.kubernetes.io/name=external-dns

# Verify it can see your Ingress resources
kubectl get ingress -A
```

### Common issues

| Symptom | Likely Cause | Fix |
|---|---|---|
| ClusterIssuer stays `NotReady` | Invalid Cloudflare token or email | Verify token permissions and email |
| Challenge stuck in `pending` | Cloudflare token lacks DNS edit permission | Recreate token with correct scopes |
| DNS records not appearing | `domainFilters` doesn't match Ingress host | Ensure the Ingress hostname ends with a filtered domain |
| Certificate issued but not trusted | Using staging ACME server | Ensure `clusterIssuer.server` points to the production URL |

## Updating Dependencies

```bash
# Update Chart.yaml with new versions, then:
helm dependency update /stacks/baseline/

# Redeploy
helm upgrade baseline /stacks/baseline/ --reuse-values
```

## Uninstall

```bash
helm uninstall baseline

# cert-manager CRDs are retained by default (helm.sh/resource-policy: keep).
# To fully remove them:
kubectl delete crd -l app.kubernetes.io/name=cert-manager
```
