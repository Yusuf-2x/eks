# EKS Project — Full Plan

**Goal:** the 2048 game (in `app/`) running on Amazon EKS, reachable at
`https://eks.<your-domain>`, with everything automated: Terraform → CI/CD → ArgoCD
→ cert-manager / ExternalDNS → Prometheus / Grafana.

Assignment source: https://github.com/CoderCo-Learning/eks-assignment-v1

---

## 0. Before you start (one-off setup)

### Accounts you need
| What | Why | Notes |
|---|---|---|
| AWS account | Everything runs here | Use an IAM user/SSO role with admin, **not** the root user |
| A domain name | `eks.<domain>` + HTTPS cert | Buy one in Route 53 (~$3–15/yr for `.click`, `.link`, `.co.uk`) or move an existing one's nameservers to Route 53 |
| GitHub account | Your repo + GitHub Actions CI/CD | Create a new **empty** repo, e.g. `eks-project` |

### Tools to install (Windows — run in PowerShell)
```powershell
winget install Hashicorp.Terraform
winget install Amazon.AWSCLI
winget install Kubernetes.kubectl
winget install Helm.Helm
winget install Git.Git
pip install checkov          # needs Python
winget install AquaSecurity.Trivy
```
Close and reopen your terminal afterwards, then check: `terraform version`, `aws --version`, `kubectl version --client`, `helm version`.

### Connect the AWS CLI
```powershell
aws configure          # access key, secret, region eu-west-2, output json
aws sts get-caller-identity   # should print your account ID
```

### ⚠️ AWS account notes (updated 2026-10-31)
- **Login:** IAM user `yusuf` (ADMIN group) in account `590184076390` (alias `aws-mustafa-v9` — Mustafa's account, so costs land there). Keys are in the `default` CLI profile.
- **Region: `eu-west-2` (London)** for everything. The CLI default is also eu-west-2.
- Mustafa's own resources live in the same region. **Don't touch them** — e.g. the ECR repo called `eks-project` (from 2024) is *not* ours; ours is `eks-2048`.
- The account is not in an AWS Organization, so there are no region locks and **IAM OIDC providers are allowed**:
  - pods still get AWS permissions via **EKS Pod Identity** (the modern way, no OIDC needed)
  - GitHub Actions (Task 5) can use **GitHub OIDC** (no long-lived keys)
- EC2 limit: 64 vCPUs (plenty for the few nodes Auto Mode will launch).
- *(Before 2026-10-31 the project used `yusuf-admin` in `166390307172`, which was locked to eu-north-1. Not used any more.)*

### 💸 Cost warning — read this
EKS is **not** free tier. Rough running cost in eu-west-2 (London):

| Item | ~ per hour | ~ per month if left on |
|---|---|---|
| EKS control plane | $0.10 | $73 |
| Auto Mode nodes: only while pods need them. AWS picks the size; price includes the ~12% Auto Mode fee | ~$0.10 per node | $0 with no pods, ~$70+ per node |
| 1 × NAT gateway | $0.05 + data | $35+ |
| Network Load Balancer (Task 2+) | $0.025 | $18 |
| KMS key for Secrets | — | $1 |
| **Total** (empty cluster → cluster with apps on 2 nodes) | **~$0.15 → ~$0.40/hr** | **~$110 → ~$290/month** |

👉 Work in sessions: `terraform apply` when you start, `terraform destroy` when you stop.
A day of work ≈ $2–3. **Set an AWS Budget alert** (Billing → Budgets → $20) before you deploy anything.

---

## 1. Repo layout (what you'll end up with)

```
eks-project/
├── app/                    # 2048 game + hardened Dockerfile/nginx.conf     ✅ container
├── terraform/
│   ├── ecr/                # stack: ECR repo for the app image (long-lived) ✅ applied
│   ├── modules/
│   │   ├── vpc/            # VPC, subnets, NAT, flow logs                ✅ Task 1
│   │   ├── iam/            # cluster + node IAM roles (Auto Mode)        ✅ Task 1
│   │   ├── eks/            # Auto Mode cluster, KMS, logs, admin access   ✅ Task 1
│   │   ├── ecr/            # hardened ECR repository                      ✅
│   │   └── pod-identity/   # IAM roles for cert-manager/ExternalDNS      ⏳ Task 3/4
│   └── main.tf ...         # stack: cluster (vpc + iam + eks modules)     ✅ Task 1 (not applied)
│   (state bucket: created by hand, see docs/REMOTE-STATE.md)             ✅
├── k8s/                    # Kubernetes manifests or Helm chart for the app ⏳
├── argocd/                 # ArgoCD Applications (app-of-apps)            ⏳
├── .github/workflows/      # CI/CD pipelines                              ⏳
└── docs/                   # guides + architecture diagram                ✅ / ⏳
```

---

## 2. The tasks, in the order to do them

> Do them in this order — each one builds on the previous.

### ✅ Task 1 — AWS infrastructure with Terraform  *(done — see `docs/TASK-1-GUIDE.md`)*
- Remote state: S3 bucket created by hand (versioned, encrypted, private, HTTPS-only), S3 native locking (`use_lockfile`). See `docs/REMOTE-STATE.md`.
- VPC across 2 AZs: public subnets (load balancer, NAT) + private subnets (nodes)
- IAM: cluster role (Auto Mode policies) + minimal node role (join cluster + pull from ECR)
- EKS **Auto Mode**: AWS runs the nodes (Bottlerocket, IMDSv2, encrypted, auto-patched) and the core add-ons (CNI, CoreDNS, EBS CSI, load balancer controller, Pod Identity). Encrypted secrets (KMS), all control-plane logs, API limited to your IP, explicit admin access entries.
- **Done when:** `kubectl get nodepools` shows `general-purpose` + `system`, and a test pod makes a node appear (see the guide).

### ⏳ Task 2 — NGINX Ingress Controller
- `helm install ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx --create-namespace` with values that ask Auto Mode's built-in load balancer controller for an **NLB**: `controller.service.loadBalancerClass=eks.amazonaws.com/nlb` plus the annotation `service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing` (Auto Mode's default is *internal*).
- This creates an AWS load balancer in your **public** subnets (that's what the `kubernetes.io/role/elb` subnet tags are for).
- Deploy the app (Deployment + Service + Ingress with `ingressClassName: nginx`).
- **Done when:** the NLB's DNS name in a browser shows the game over HTTP.

### ⏳ Task 3 — cert-manager (HTTPS)
- Install cert-manager with Helm (`crds.enabled=true`).
- Create a `ClusterIssuer` for Let's Encrypt. Start with **staging** issuer (no rate limits), switch to **prod** once it works.
- Solver: HTTP-01 via nginx is easiest; DNS-01 via Route 53 is more robust (needs an IAM role → use EKS Pod Identity: `aws_eks_pod_identity_association`).
- Add `cert-manager.io/cluster-issuer` annotation + `tls:` block to the app Ingress.
- **Done when:** `kubectl get certificate` shows `READY=True`.

### ⏳ Task 4 — ExternalDNS
- Terraform: Route 53 hosted zone (or data lookup of existing one) + IAM role allowing `route53:ChangeResourceRecordSets` on **that zone only**, bound to the `external-dns` service account.
- Helm install ExternalDNS with `provider=aws`, `domainFilters=[<your-domain>]`, `policy=upsert-only` (safe) or `sync`.
- **Done when:** `eks.<domain>` appears in Route 53 automatically and `https://eks.<domain>` loads with a valid padlock. 🎉 (Tasks 2–4 together = the app is "live").

### ⏳ Task 5 — CI/CD (GitHub Actions)
Auth: the current account allows OIDC, so use **GitHub OIDC** (an IAM role GitHub assumes per run, no stored keys). Fallback: a dedicated CI IAM user with keys in GitHub **encrypted secrets**.
- **Pipeline 1 – Terraform:** on PR → `fmt -check`, `validate`, `tflint`, `plan` (post plan as PR comment). On merge to `main` → `apply`. Manual `workflow_dispatch` for `destroy`.
- **Pipeline 2 – App:** Checkov scan of `terraform/` → `docker build` → Trivy scan (fail on HIGH/CRITICAL) → push to **ECR** (tag = git SHA) → update image tag in `k8s/` and commit → ArgoCD deploys it.
- Needs: `app/Dockerfile` ✅ (done — hardened, see `docs/CONTAINER-GUIDE.md`), ECR repo in Terraform ✅ (`terraform/ecr`, repo `eks-2048`).

### ⏳ Task 6 — ArgoCD (GitOps)
- Install ArgoCD with Helm; expose UI at `argocd.<domain>` via the same Ingress/cert-manager/ExternalDNS setup.
- Create an `Application` pointing at `k8s/` in your repo with `syncPolicy.automated: {prune: true, selfHeal: true}`.
- Optional but impressive: "app of apps" — ArgoCD also manages ingress-nginx, cert-manager, ExternalDNS, monitoring.
- **Done when:** changing replicas in Git changes the cluster with no `kubectl apply`.

### ⏳ Task 7 — Prometheus + Grafana
- Helm install `kube-prometheus-stack` (Prometheus, Grafana, node-exporter, kube-state-metrics in one chart).
- Enable ingress-nginx metrics (`controller.metrics.enabled=true`, `serviceMonitor.enabled=true`).
- Grafana at `grafana.<domain>`. Dashboards: CPU/memory by node & pod, pod restarts/health, node status, ingress request rate/latency/5xx (Grafana dashboard ID 9614 / the official ingress-nginx dashboard).
- Persistent Prometheus data: Auto Mode already includes EBS storage. Just create a `StorageClass` with `provisioner: ebs.csi.eks.amazonaws.com` (gp3, encrypted).

### ⏳ Task 8 — Architecture diagram
- Mermaid in `docs/architecture.md` (renders on GitHub) or draw.io.
- Must show: VPC/subnets/SGs/IAM, user → Route 53 → NLB → NGINX → Service → Pods, ExternalDNS → Route 53, cert-manager ↔ Let's Encrypt, GitHub → Actions → ECR + Git → ArgoCD → cluster, Prometheus → Grafana.

---

## 3. Key concepts in plain English

| Term | What it means here |
|---|---|
| **VPC** | Your private network in AWS. |
| **Public vs private subnet** | Public = has a route to the Internet Gateway (things here can be reached from the internet). Private = no inbound route from the internet; outbound goes via NAT. Nodes live in private, the load balancer lives in public. |
| **NAT gateway** | Lets private nodes download images/updates without being reachable from outside. |
| **EKS control plane** | The Kubernetes "brain" (API server, etcd). AWS runs it; you pay $0.10/hr. |
| **EKS Auto Mode** | AWS launches/patches/removes the EC2 nodes that run your pods, and runs the core add-ons. You never manage a node group. |
| **Security group** | Stateful firewall on each network interface. |
| **IAM role** | A set of AWS permissions something can "assume" (EKS, EC2 nodes, a pod, GitHub Actions). |
| **Pod Identity** | How one specific pod gets its own IAM role (e.g. only ExternalDNS can edit Route 53). (IRSA/OIDC is the older way.) |
| **Remote state + lock** | Terraform's memory of what it created, stored safely in S3; a `.tflock` file in the bucket stops two runs clashing. |
| **Ingress controller** | A reverse proxy (NGINX) inside the cluster that routes `eks.<domain>` → your app's Service. |
| **GitOps** | Git is the source of truth; ArgoCD continuously makes the cluster match Git. |

---

## 4. Progress tracker

- [x] Task 1 code written for EKS Auto Mode, 4 modules; validate + plan (39 to add) pass; Checkov 0 failed, Trivy 0
- [x] Remote state: S3 bucket made by hand, S3 native locking, DynamoDB removed (`docs/REMOTE-STATE.md`)
- [ ] Task 1 deployed to AWS (`kubectl get nodepools` + test pod gets a node)
- [ ] Task 1 pushed to your GitHub repo
- [x] App containerised + hardened (`docs/CONTAINER-GUIDE.md`) — Trivy/Checkov clean
- [x] ECR repo `eks-2048` created in eu-west-2 (now via `modules/ecr`); image `ec0b220` pushed, ECR scan 0 findings
- [ ] Task 2 — ingress-nginx + app over HTTP
- [ ] Task 3 — cert-manager, HTTPS
- [ ] Task 4 — ExternalDNS, `https://eks.<domain>` live
- [ ] Task 5 — CI/CD pipelines
- [ ] Task 6 — ArgoCD
- [ ] Task 7 — Prometheus/Grafana dashboards
- [ ] Task 8 — Architecture diagram
- [ ] Final: README with screenshots, everything destroyed when not in use
