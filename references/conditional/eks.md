# AWS EKS — Where Managed Kubernetes Flips Vanilla Intuitions

> Loaded only when an EKS platform signal is detected (e.g. `eks.amazonaws.com` annotations,
> `aws-auth` ConfigMap, `vpc.amazonaws.com/*` labels, ALB/NLB controller annotations,
> `kubernetes.io/cluster/<name>` tags, or an `arn:aws:...` in kubeconfig).

## What flips vs vanilla Kubernetes

| Concern | Vanilla intuition | On EKS |
|---|---|---|
| Pod → cloud API auth | Bake a Secret with static keys | **Never** — pods get short-lived STS creds via IRSA or Pod Identity |
| Pod IPs | Overlay CIDR, invisible to the network | **Real VPC IPs** from the subnet — the network sees every pod |
| Pods per node | ~110 default, CPU/mem-bound | **ENI/IP-bound** — a `t3.small` caps at 11 pods regardless of free CPU |
| `type: LoadBalancer` | kube-proxy + cloud LB to NodePort | AWS LB Controller provisions NLB, often **targeting pod IPs directly** (bypasses kube-proxy) |
| Ingress | Needs an in-cluster ingress controller pod | AWS LB Controller provisions a **real ALB** outside the cluster |
| PVs | Schedule pod anywhere | EBS volumes are **AZ-pinned** — pod is nailed to one AZ |
| etcd backup | You snapshot etcd | **You can't** — control plane is AWS-managed; back up *workloads/PVs* (Velero) instead |
| Node scaling | Cluster Autoscaler on fixed ASGs | Karpenter provisions right-sized nodes just-in-time; or Fargate = no nodes |
| Cluster access | Edit kubeconfig | `aws eks update-kubeconfig` + IAM identity mapping (access entries / aws-auth) |

---

## 1. Identity: how pods get AWS permissions

Two mechanisms. Both hand the pod **temporary STS credentials** — never store long-lived keys.

### IRSA (IAM Roles for Service Accounts) — the OIDC way

The cluster exposes an OIDC provider. A projected SA token is exchanged with STS for role creds.

Setup:
```bash
# 1. Associate an OIDC provider with the cluster (once per cluster)
eksctl utils associate-iam-oidc-provider --cluster my-cluster --approve

# 2. Create a role + annotated ServiceAccount in one shot
eksctl create iamserviceaccount \
  --cluster my-cluster \
  --namespace payments \
  --name checkout-sa \
  --attach-policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess \
  --approve
```

The SA carries the wiring:
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: checkout-sa
  namespace: payments
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::111122223333:role/checkout-role
```

The IAM role's **trust policy** scopes it to exactly one SA (least privilege at the identity layer):
```json
{
  "Effect": "Allow",
  "Principal": { "Federated": "arn:aws:iam::111122223333:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/EXAMPLE" },
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": {
    "StringEquals": {
      "oidc.eks.us-east-1.amazonaws.com/id/EXAMPLE:sub": "system:serviceaccount:payments:checkout-sa",
      "oidc.eks.us-east-1.amazonaws.com/id/EXAMPLE:aud": "sts.amazonaws.com"
    }
  }
}
```
The admission webhook injects `AWS_ROLE_ARN` and `AWS_WEB_IDENTITY_TOKEN_FILE` env + a projected token volume automatically. The AWS SDK picks them up with zero code changes.

### EKS Pod Identity — the newer, simpler way

An **EKS add-on agent** (DaemonSet) hands creds via a local endpoint. No OIDC trust-policy editing, no per-cluster provider, and associations are reusable across clusters.

```bash
# Enable the add-on once
aws eks create-addon --cluster-name my-cluster --addon-name eks-pod-identity-agent

# Associate a role to a namespace/SA — no trust-policy juggling
aws eks create-pod-identity-association \
  --cluster-name my-cluster \
  --namespace payments \
  --service-account checkout-sa \
  --role-arn arn:aws:iam::111122223333:role/checkout-role
```
The role trusts the service principal `pods.eks.amazonaws.com` (assumed via `sts:AssumeRole` + `sts:TagSession`), not a per-cluster OIDC subject.

### Which to use

- **Pod Identity** for new work: less setup, reusable across clusters, no OIDC-URL churn, supports role session tags. Preferred default in 2024+.
- **IRSA** when you need: cross-account trust via OIDC, EKS Fargate (Pod Identity agent doesn't run on Fargate), or an older cluster/tooling that predates Pod Identity.
- **Least privilege either way:** one role per workload, scoped policies, no wildcard `*` on resources. Two pods that need different data get two SAs and two roles.

---

## 2. Networking: AWS VPC CNI (real VPC IPs)

The default CNI (`aws-node` DaemonSet) gives every pod a **routable VPC IP** from the node's subnet via secondary IPs on Elastic Network Interfaces (ENIs). No overlay, no NAT between pods.

### The ENI limit → max-pods trap

Max pods per node is **not** CPU/memory-bound; it's `(#ENIs × (IPs-per-ENI − 1)) + 2`. Small instances run out of IPs long before CPU:

| Instance | ENIs | IPs/ENI | Max pods (default) |
|---|---|---|---|
| t3.small | 3 | 4 | 11 |
| t3.medium | 3 | 6 | 17 |
| m5.large | 3 | 10 | 29 |
| m5.4xlarge | 8 | 30 | 234 |

Formula and the canonical table: AWS publishes `eni-max-pods.txt`. `kubelet` on managed nodes is bootstrapped with the right `--max-pods`.

### Prefix delegation — escape the IP ceiling

Assign /28 IPv4 **prefixes** to ENIs instead of individual IPs. Pod density jumps ~16× (an m5.large goes from 29 → up to 110, capped by kubelet):
```bash
kubectl set env daemonset aws-node -n kube-system ENABLE_PREFIX_DELEGATION=true
# Then raise --max-pods on the nodes (e.g. bootstrap arg or nodeadm config):
#   --max-pods=110
```
Watch subnet exhaustion — prefixes reserve 16 IPs at a time.

### Security groups for pods

Attach EC2 **security groups directly to pods** (not just nodes) for fine-grained egress/ingress to RDS, etc.:
```bash
kubectl set env daemonset aws-node -n kube-system ENABLE_POD_ENI=true
```
```yaml
apiVersion: vpcresources.k8s.aws/v1beta1
kind: SecurityGroupPolicy
metadata:
  name: db-clients
  namespace: payments
spec:
  podSelector:
    matchLabels: { app: checkout }
  securityGroups:
    groupIds: [ sg-0123456789abcdef0 ]
```
Requires nitro instances; those pods get a branch ENI.

---

## 3. Load balancing: AWS Load Balancer Controller

Install the controller (it needs its own IRSA/Pod Identity role). It watches Ingress and Service objects and provisions real AWS LBs.

### Ingress → ALB

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: web
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip          # ip = target pods directly
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
    alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:us-east-1:111122223333:certificate/abc
    alb.ingress.kubernetes.io/healthcheck-path: /healthz
    alb.ingress.kubernetes.io/group.name: shared-alb    # share one ALB across Ingresses
spec:
  ingressClassName: alb
  rules:
    - host: app.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend: { service: { name: web, port: { number: 80 } } }
```

### Service → NLB

```yaml
apiVersion: v1
kind: Service
metadata:
  name: grpc-api
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: external
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
    service.beta.kubernetes.io/aws-load-balancer-scheme: internal
spec:
  type: LoadBalancer
  loadBalancerClass: service.k8s.aws/nlb
  ports: [ { port: 443, targetPort: 8443 } ]
  selector: { app: grpc-api }
```

### target-type: `ip` vs `instance`

- **`ip`** (preferred): LB targets pod IPs directly (works because VPC CNI gives real IPs). Bypasses kube-proxy/NodePort → fewer hops, preserves source IP cleanly, works with Fargate. Requires the LB controller.
- **`instance`**: LB targets node NodePorts; traffic hops through kube-proxy to a pod (possibly on another node). Needed only when you must use `instance` targets or the in-tree controller.

---

## 4. Storage: EBS, EFS, and AZ pinning

### EBS CSI (block, RWO) — use gp3

Install the `aws-ebs-csi-driver` add-on (needs its own IRSA/Pod Identity role).
```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer   # critical — see below
parameters:
  type: gp3
  iops: "3000"
  throughput: "125"
  encrypted: "true"
```
**AZ pinning is the flip:** an EBS volume lives in one AZ; the pod using it can only schedule in that AZ. Always use `WaitForFirstConsumer` so the volume is created in the same AZ the pod lands in — otherwise you get pods stuck Pending with `volume node affinity conflict`. The CSI driver stamps topology:
```yaml
nodeAffinity:
  required:
    nodeSelectorTerms:
      - matchExpressions:
          - { key: topology.ebs.csi.aws.com/zone, operator: In, values: [us-east-1a] }
```

### EFS CSI (shared, RWX)

For `ReadWriteMany`, EBS can't do it — use EFS (an NFS filesystem, region-wide, not AZ-pinned):
```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: efs
provisioner: efs.csi.aws.com
parameters:
  provisioningMode: efs-ap        # dynamic access points
  fileSystemId: fs-0123456789abcdef0
  directoryPerms: "700"
```
EFS is slower and pricier per GB than EBS — use it only when you genuinely need shared read/write across pods/AZs.

---

## 5. Autoscaling & nodes: managed node groups vs Fargate vs Karpenter

| Option | What it is | Use when | Tradeoffs |
|---|---|---|---|
| **Managed node groups** | EKS-managed EC2 ASGs, scaled by Cluster Autoscaler | Predictable, simple, need DaemonSets/GPU/host access | You still pick instance types; bin-packing is coarse; scale-up is slow |
| **Fargate** | Serverless pods, one micro-VM per pod, no nodes | Bursty/isolated workloads, no node ops, per-pod billing | No DaemonSets, no privileged pods, no GPU, no host paths; pricier per vCPU; slower cold start; IRSA only (no Pod Identity) |
| **Karpenter** (favored) | Groupless autoscaler that provisions right-sized nodes just-in-time from a `NodePool` | Most production clusters — cost + speed | Adds a controller to run; you manage `NodePool`/`EC2NodeClass` |

Karpenter picks the cheapest instance that fits pending pods, consolidates underused nodes, and does spot/on-demand mixing natively:
```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata: { name: default }
spec:
  template:
    spec:
      requirements:
        - { key: karpenter.sh/capacity-type, operator: In, values: [spot, on-demand] }
        - { key: kubernetes.io/arch, operator: In, values: [amd64, arm64] }
      nodeClassRef: { group: karpenter.k8s.aws, kind: EC2NodeClass, name: default }
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 30s
```
Karpenter is the favored path: faster scale-up (no ASG round-trip), tighter bin-packing (lower cost), and no instance-type guesswork.

---

## 6. Control plane: managed means you can't touch etcd

The API server and etcd are AWS-run across 3 AZs. Consequences:

- **No etcd snapshots.** Your DR strategy is workload + PV backup, not etcd backup. Use **Velero** with the EBS/EFS snapshot plugin:
  ```bash
  velero install --provider aws --bucket my-eks-backups \
    --plugins velero/velero-plugin-for-aws:v1.10.0 \
    --backup-location-config region=us-east-1
  velero backup create nightly --include-namespaces payments --snapshot-volumes
  ```
- **Control-plane logging** is opt-in per log type (worth enabling `authenticator`, `audit`):
  ```bash
  aws eks update-cluster-config --name my-cluster \
    --logging '{"clusterLogging":[{"types":["api","audit","authenticator","controllerManager","scheduler"],"enabled":true}]}'
  ```
- **Add-ons** (vpc-cni, coredns, kube-proxy, ebs-csi, pod-identity-agent) are managed lifecycle objects — update them explicitly:
  ```bash
  aws eks update-addon --cluster-name my-cluster --addon-name vpc-cni --addon-version v1.18.0-eksbuild.1
  ```
- **Version cadence:** EKS ships a new K8s minor roughly quarterly; each version gets standard support ~14 months, then extended support (extra cost). You must upgrade the control plane first, then node groups/add-ons. Skipping minors is not allowed — go one at a time.

---

## 7. Access: from kubeconfig to IAM identity

Get credentials:
```bash
aws eks update-kubeconfig --region us-east-1 --name my-cluster
# writes an exec entry that calls `aws eks get-token` — auth is your IAM identity
```

### aws-auth ConfigMap (legacy) → EKS access entries (current)

Historically, mapping IAM principals to K8s RBAC meant hand-editing the `aws-auth` ConfigMap in `kube-system` — one typo locked everyone out, and it wasn't auditable via API.

Modern EKS uses **access entries** (first-class API, CloudTrail-audited):
```bash
aws eks create-access-entry --cluster-name my-cluster \
  --principal-arn arn:aws:iam::111122223333:role/Developers

aws eks associate-access-policy --cluster-name my-cluster \
  --principal-arn arn:aws:iam::111122223333:role/Developers \
  --access-scope type=namespace,namespaces=payments \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy
```
Set the cluster's `authenticationMode` to `API` or `API_AND_CONFIG_MAP`. Prefer access entries for new clusters; migrate off aws-auth where you can.

---

## 8. Common failures branch (for operating)

### Pod stuck `Pending` — no ENI IPs left
Symptom: `0/3 nodes are available: too many pods` or events showing failed IP allocation.
- The node hit its ENI/IP cap, not its CPU/mem cap. Check `kubectl describe node` for `pods` allocatable.
- Fixes: enable prefix delegation (`ENABLE_PREFIX_DELEGATION=true` + raise `--max-pods`), scale out nodes, or use larger instances. Also check the **subnet** isn't out of free IPs (`aws ec2 describe-subnets`).

### `ImagePullBackOff` from ECR
- The node/pod identity lacks `ecr:GetAuthorizationToken` + `BatchGetImage`. Managed node roles usually have `AmazonEC2ContainerRegistryReadOnly` — verify it's attached.
- Cross-account/cross-region ECR needs an explicit repository policy and the correct registry URL.
- Check: `aws ecr get-login-password | ...`, `kubectl describe pod` for the exact auth error.

### Pod can't assume role — IRSA/Pod Identity misconfig
Symptom: `AccessDenied` / `WebIdentityErr` / `is not authorized to perform sts:AssumeRoleWithWebIdentity`.
- **IRSA checklist:** OIDC provider associated with the cluster? SA annotation `eks.amazonaws.com/role-arn` correct? Trust policy `sub` matches `system:serviceaccount:<ns>:<sa>` exactly? Pod actually using that SA (`serviceAccountName:` set)? Env vars injected (`kubectl exec ... env | grep AWS_`)? Restart the pod after fixing the SA — the webhook only injects at admission.
- **Pod Identity checklist:** agent add-on running? Association exists for this exact namespace/SA? Role trust allows `pods.eks.amazonaws.com`?
- Fargate + Pod Identity won't work — use IRSA there.
