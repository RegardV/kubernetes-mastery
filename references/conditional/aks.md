# Azure AKS — Essentials (High-Impact Differences)

> Loaded only when an AKS platform signal is detected (e.g. `azure.workload.identity/*`
> annotations/labels, `kubenet`/`azure` CNI references, AGIC annotations, `disk.csi.azure.com`
> / `file.csi.azure.com` provisioners, or an `az aks` kubeconfig context).

## What flips vs vanilla Kubernetes

| Concern | Vanilla | On AKS |
|---|---|---|
| Pod → cloud auth | Static credentials | **Entra Workload ID** — federate a KSA to a managed identity, no secrets |
| Pod IPs | Overlay | **Azure CNI** gives real VNet IPs; or **CNI Overlay** for scale; kubenet is legacy |
| Ingress | In-cluster controller | **AGIC / Application Gateway**, or the newer App Routing (managed NGINX) |
| PVs | Generic SC | Azure Disk (RWO, **zone-pinned**) / Azure Files (RWX) CSI |
| etcd / control plane | You run it | Microsoft-managed — no etcd access; back up workloads/PVs instead |

## Identity: Microsoft Entra Workload ID

The current model (replaces the deprecated pod-managed identity / aad-pod-identity). A projected SA token is federated to a user-assigned **managed identity** via OIDC — pods get tokens, no secrets.

```bash
az aks update -g rg -n my-cluster --enable-oidc-issuer --enable-workload-identity

# Federate the KSA to the managed identity
az identity federated-credential create --name checkout-fic \
  --identity-name checkout-mi --resource-group rg \
  --issuer "$(az aks show -g rg -n my-cluster --query oidcIssuerProfile.issuerUrl -o tsv)" \
  --subject system:serviceaccount:payments:checkout-sa \
  --audience api://AzureADTokenExchange
```
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: checkout-sa
  namespace: payments
  annotations:
    azure.workload.identity/client-id: <managed-identity-client-id>
---
# Pod template must carry the label to get token injection:
#   labels: { azure.workload.identity/use: "true" }
```
Grant that managed identity Azure RBAC roles (e.g. Storage Blob Data Reader) — least privilege, one identity per workload.

## Networking: Azure CNI vs kubenet + Overlay

- **kubenet (legacy):** pods get overlay IPs, node routes via UDR; low VNet IP usage but limited features. Being phased out — avoid for new clusters.
- **Azure CNI:** every pod gets a **real VNet IP** — routable, integrates with NSGs and VNet peering, supports Windows nodes. Cost: consumes VNet address space fast.
- **Azure CNI Overlay:** pods use a private overlay CIDR (like kubenet) but with CNI features and far better scale/perf — **the recommended default** for large clusters that would exhaust VNet IPs.
- **Azure CNI Powered by Cilium** adds eBPF dataplane + NetworkPolicy.

```bash
az aks create -g rg -n my-cluster \
  --network-plugin azure --network-plugin-mode overlay \
  --network-dataplane cilium
```

## Ingress: AGIC / Application Gateway

AGIC (Application Gateway Ingress Controller) programs an Azure **Application Gateway** (L7 LB, WAF-capable) from Ingress objects:
```yaml
metadata:
  annotations:
    kubernetes.io/ingress.class: azure/application-gateway
    appgw.ingress.kubernetes.io/ssl-redirect: "true"
```
The newer **App Routing** add-on offers a managed NGINX ingress if you don't need App Gateway/WAF. `type: LoadBalancer` provisions an Azure Load Balancer (L4).

## Storage: Disk & Files CSI

```yaml
# Azure Disk — RWO, zone-pinned (use WaitForFirstConsumer)
provisioner: disk.csi.azure.com
parameters: { skuName: Premium_LRS }
volumeBindingMode: WaitForFirstConsumer
---
# Azure Files — RWX (SMB/NFS), region-wide
provisioner: file.csi.azure.com
parameters: { skuName: Standard_LRS }
```
Azure Disk is zone-pinned (pod nailed to the disk's zone); use Azure Files for `ReadWriteMany`.

## Nodes & autoscaling

- **Node pools:** system pool (runs CoreDNS/metrics) + user pools; separate pools for GPU/spot/Windows.
- **Cluster autoscaler** per node pool (`--enable-cluster-autoscaler --min-count --max-count`).
- **NAP (node auto-provisioning)** — Karpenter-based provisioning of right-sized nodes (newer).
- **Spot node pools** for cheap interruptible capacity; **Virtual Nodes** (ACI) for serverless burst.

## Access & ops

```bash
az aks get-credentials -g rg -n my-cluster        # writes kubeconfig (Entra exec auth)
```
- Use **Entra + Azure RBAC for Kubernetes** so `kubectl` authz maps to Azure roles.
- Control plane is managed (Free vs **Standard**/**Premium** tier for SLA/long-term support). No etcd access — DR via Velero or **Azure Backup for AKS**.
- Auto-upgrade channels (`patch`, `stable`, `rapid`) + maintenance windows keep versions current.
