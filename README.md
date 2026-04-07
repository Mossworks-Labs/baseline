# Baseline Stack

Cluster-level infrastructure for TLS certificates and dynamic DNS, deployed as a single Helm umbrella chart.

## What It Does

| Component | Purpose |
|---|---|
| **cert-manager** (Jetstack v1.17.1) | Automates TLS certificate issuance and renewal via Let's Encrypt |
| **external-dns** (kubernetes-sigs v1.20.0) | Syncs Kubernetes Ingress hostnames to Cloudflare DNS records |
| **ClusterIssuer** | ACME issuer using DNS-01 challenge through Cloudflare |
| **Certificate** | Wildcard cert for `example.com` + `*.example.com` + extra SANs |
| **Cloudflare Tunnel** | Exposes cluster services to the internet without port forwarding |

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
4. Under **Zone Resources**, select the target zone
5. Save the token — you'll need it for deployment

## Deployment

### Quick deploy

```bash
bash scripts/deploy.sh
```

### Manual steps

```bash
# 1. Update subchart dependencies
helm dependency update .

# 2. Configure values-dev.yaml with your domain, Cloudflare token, and tunnel credentials

# 3. Deploy
helm upgrade --install baseline . -f values-dev.yaml
```

The chart manages cert-manager CRDs automatically (`cert-manager.crds.enabled: true`). The Cloudflare token is stored in a Kubernetes Secret (`baseline-cloudflare`) and read by both cert-manager (DNS-01 solver) and external-dns (`CF_API_TOKEN` env var).

## Verification

```bash
# cert-manager pods (controller, webhook, cainjector)
kubectl get pods -l app.kubernetes.io/instance=baseline -l app.kubernetes.io/name=cert-manager

# external-dns pod
kubectl get pods -l app.kubernetes.io/name=external-dns

# ClusterIssuer is ready
kubectl get clusterissuer letsencrypt-prod

# Certificate is issued
kubectl get certificate

# TLS secret exists with correct SANs
kubectl get secret baseline-tls -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -subject -ext subjectAltName
```

## Values Reference

### Top-Level

| Key | Default | Description |
|---|---|---|
| `domain` | `example.com` | Base domain for the wildcard certificate |
| `cloudflare.email` | `""` | Cloudflare account email (used by cert-manager ACME) |
| `cloudflare.apiToken` | `""` | Cloudflare API token (used by cert-manager DNS-01 solver + external-dns) |

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
| `certificate.extraDnsNames` | `[]` | Additional SANs beyond the wildcard (e.g. `["*.local.example.com"]` for multi-level subdomains) |

### cert-manager (subchart)

| Key | Default | Description |
|---|---|---|
| `cert-manager.enabled` | `true` | Deploy cert-manager |
| `cert-manager.crds.enabled` | `true` | Install cert-manager CRDs (set `false` if applied manually) |

Full subchart values: [cert-manager docs](https://artifacthub.io/packages/helm/cert-manager/cert-manager)

### external-dns (subchart — kubernetes-sigs/external-dns)

| Key | Default | Description |
|---|---|---|
| `external-dns.enabled` | `true` | Deploy external-dns |
| `external-dns.provider.name` | `cloudflare` | DNS provider |
| `external-dns.domainFilters` | `[example.com]` | Limit which domains external-dns manages |
| `external-dns.policy` | `upsert-only` | Only create/update records, never delete |
| `external-dns.txtOwnerId` | `baseline` | TXT record owner ID for record ownership tracking |
| `external-dns.sources` | `[ingress]` | Kubernetes resource types to watch |

The Cloudflare API token is read from the `baseline-cloudflare` Secret via the `CF_API_TOKEN` env var.

Full subchart values: [external-dns docs](https://github.com/kubernetes-sigs/external-dns/tree/master/charts/external-dns)

## How Other Stacks Consume This

Once baseline is deployed, other Helm charts reference the `baseline-tls` secret for TLS:

```yaml
# In the consuming chart's ingress:
spec:
  tls:
    - secretName: baseline-tls    # Wildcard cert from baseline
      hosts:
        - myapp.example.com
```

The wildcard cert (`*.example.com`) covers any single-level subdomain. For multi-level subdomains (e.g. `dev.local.example.com`), add them to `certificate.extraDnsNames`.

external-dns automatically creates Cloudflare DNS records for any Ingress hostname matching the `domainFilters`.

## Architecture

```
                          Cloudflare DNS
                         +---------------+
                         | A  *.domain   |
                         | TXT ownership |
                         +------^---^----+
                                |   |
                   DNS sync     |   |  DNS-01 challenge
                                |   |
                 +--------------+   +--------------+
                 |                                  |
          +------+------+                   +-------+-------+
          | external-dns|                   |  cert-manager |
          |             |                   |  (controller) |
          +------^------+                   +-------^-------+
                 | watches                          | issues
                 |                                  |
          +------+------+                   +-------+-------+
          |   Ingress   |                   | ClusterIssuer |
          |  resources  |                   | letsencrypt-  |
          |             |                   |   prod        |
          +-------------+                   +---------------+
```

## Troubleshooting

### cert-manager not issuing certificates

```bash
kubectl describe certificate baseline-tls
kubectl get certificaterequest,order,challenge
kubectl logs -l app.kubernetes.io/name=cert-manager -l app.kubernetes.io/component=controller
```

### external-dns not creating DNS records

```bash
kubectl logs -l app.kubernetes.io/name=external-dns
kubectl get ingress -A
```

### Common issues

| Symptom | Cause | Fix |
|---|---|---|
| ClusterIssuer stays `NotReady` | Invalid Cloudflare token or email | Verify token permissions and email |
| Challenge stuck in `pending` | Cloudflare token lacks DNS edit permission | Recreate token with correct scopes |
| DNS records not appearing | `domainFilters` doesn't match Ingress host | Ensure the Ingress hostname ends with a filtered domain |
| Certificate issued but not trusted | Using staging ACME server | Ensure `clusterIssuer.server` points to the production URL |
| `Too many authentication failures` | Bad token caused rate limit | Fix the token, wait a few minutes, delete stale CertificateRequests |
| CRD errors on first install | cert-manager CRDs not yet installed | Apply CRDs manually first (see step 2) |

## Updating Dependencies

```bash
# Update Chart.yaml with new versions, then:
helm dependency update .

# Redeploy
helm upgrade baseline . --reuse-values
```

## Uninstall

```bash
helm uninstall baseline

# cert-manager CRDs are retained by default (helm.sh/resource-policy: keep).
# To fully remove them:
kubectl delete crd -l app.kubernetes.io/name=cert-manager
```
