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
aws configure          # access key, secret, region eu-north-1, output json
aws sts get-caller-identity   # should print your account ID
```

### ⚠️ AWS account notes (found 2026-10-28 — read before changing regions)
- **Login:** IAM user `yusuf-admin` in account `166390307172` (keys saved in the `default` CLI profile, `AdministratorAccess` attached).
- That account sits in an AWS Organization (owner `701179922972`) whose policies **block every region except `eu-north-1` (Stockholm)**. Everything in this project uses `eu-north-1`. Any other region gives "explicit deny in a service control policy".
- The Organization also blocks **IAM OIDC providers**. So:
  - pods get AWS permissions via **EKS Pod Identity** (not IRSA)
  - GitHub Actions (Task 5) must use **access keys stored as GitHub secrets** (not GitHub OIDC)
- EC2 limit: **5 vCPUs** → max 2 × t3.medium nodes. Request an increase in Service Quotas if you need more.

### 💸 Cost warning — read this
EKS is **not** free tier. Rough running cost (eu-north-1 / Stockholm is one of the cheapest regions):

| Item | ~ per hour | ~ per month if left on |
|---|---|---|
| EKS control plane | $0.10 | $73 |
| 2 × t3.medium nodes | $0.09 | $65 |
| 1 × NAT gateway | $0.05 + data | $35+ |
| Network Load Balancer (Task 2+) | $0.025 | $18 |
| **Total** | **~$0.27/hr** | **~$190/month** |

👉 Work in sessions: `terraform apply` when you start, `terraform destroy` when you stop.
A day of work ≈ $2–3. **Set an AWS Budget alert** (Billing → Budgets → $20) before you deploy anything.

---

## 1. Repo layout (what you'll end up with)

```
eks-project/
├── app/                    # 2048 game + hardened Dockerfile/nginx.conf     ✅ container
├── terraform/
│   ├── bootstrap/          # S3 + DynamoDB for remote state (run once)   ✅ Task 1
│   ├── modules/
│   │   ├── vpc/            # VPC, subnets, NAT, flow logs                ✅ Task 1
│   │   ├── iam/            # cluster + node IAM roles                    ✅ Task 1
│   │   ├── eks/            # cluster, node group, SGs, add-ons            ✅ Task 1
│   │   └── pod-identity/   # IAM roles for cert-manager/ExternalDNS      ⏳ Task 3/4
│   └── main.tf ...         # root stack wiring modules together          ✅ Task 1
├── k8s/                    # Kubernetes manifests or Helm chart for the app ⏳
├── argocd/                 # ArgoCD Applications (app-of-apps)            ⏳
├── .github/workflows/      # CI/CD pipelines                              ⏳
└── docs/                   # guides + architecture diagram                ✅ / ⏳
```

---

## 2. The tasks, in the order to do them

> Do them in this order — each one builds on the previous.

### ✅ Task 1 — AWS infrastructure with Terraform  *(done — see `docs/TASK-1-GUIDE.md`)*
- Remote state: S3 bucket (versioned, encrypted, private) + DynamoDB lock table
- VPC across 2 AZs: public subnets (load balancer, NAT) + private subnets (nodes)
- IAM: cluster role + node role (least privilege, AWS managed policies)
- EKS: encrypted secrets (KMS), control-plane logs, private nodes, IMDSv2, encrypted disks, tight security groups, Pod Identity agent
- **Done when:** `kubectl get nodes` shows 2 `Ready` nodes.

### ⏳ Task 2 — NGINX Ingress Controller
- `helm install ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx --create-namespace` with values that ask for an **NLB** (`service.beta.kubernetes.io/aws-load-balancer-type: nlb`).
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
Auth: GitHub OIDC is blocked in this AWS account, so create a dedicated IAM user for CI and store its keys as GitHub **encrypted secrets** (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`).
- **Pipeline 1 – Terraform:** on PR → `fmt -check`, `validate`, `tflint`, `plan` (post plan as PR comment). On merge to `main` → `apply`. Manual `workflow_dispatch` for `destroy`.
- **Pipeline 2 – App:** Checkov scan of `terraform/` → `docker build` → Trivy scan (fail on HIGH/CRITICAL) → push to **ECR** (tag = git SHA) → update image tag in `k8s/` and commit → ArgoCD deploys it.
- Needs: `app/Dockerfile` ✅ (done — hardened, see `docs/CONTAINER-GUIDE.md`), ECR repo in Terraform.

### ⏳ Task 6 — ArgoCD (GitOps)
- Install ArgoCD with Helm; expose UI at `argocd.<domain>` via the same Ingress/cert-manager/ExternalDNS setup.
- Create an `Application` pointing at `k8s/` in your repo with `syncPolicy.automated: {prune: true, selfHeal: true}`.
- Optional but impressive: "app of apps" — ArgoCD also manages ingress-nginx, cert-manager, ExternalDNS, monitoring.
- **Done when:** changing replicas in Git changes the cluster with no `kubectl apply`.

### ⏳ Task 7 — Prometheus + Grafana
- Helm install `kube-prometheus-stack` (Prometheus, Grafana, node-exporter, kube-state-metrics in one chart).
- Enable ingress-nginx metrics (`controller.metrics.enabled=true`, `serviceMonitor.enabled=true`).
- Grafana at `grafana.<domain>`. Dashboards: CPU/memory by node & pod, pod restarts/health, node status, ingress request rate/latency/5xx (Grafana dashboard ID 9614 / the official ingress-nginx dashboard).
- Need gp3 storage: install the **EBS CSI driver** add-on (needs IAM role) if you want persistent Prometheus data.

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
| **Managed node group** | EC2 instances that run your pods. AWS handles joining/updating them. |
| **Security group** | Stateful firewall on each network interface. |
| **IAM role** | A set of AWS permissions something can "assume" (EKS, EC2 nodes, a pod, GitHub Actions). |
| **Pod Identity** | How one specific pod gets its own IAM role (e.g. only ExternalDNS can edit Route 53). (IRSA/OIDC is the older way — blocked in this AWS account.) |
| **Remote state + lock** | Terraform's memory of what it created, stored safely in S3; DynamoDB stops two runs clashing. |
| **Ingress controller** | A reverse proxy (NGINX) inside the cluster that routes `eks.<domain>` → your app's Service. |
| **GitOps** | Git is the source of truth; ArgoCD continuously makes the cluster match Git. |

---

## 4. Progress tracker

- [x] Task 1 code written + `terraform validate` passes
- [ ] Task 1 deployed to AWS (`kubectl get nodes` → 2 Ready)
- [ ] Task 1 pushed to your GitHub repo
- [x] App containerised + hardened (`docs/CONTAINER-GUIDE.md`) — Trivy/Checkov clean
- [ ] Task 2 — ingress-nginx + app over HTTP
- [ ] Task 3 — cert-manager, HTTPS
- [ ] Task 4 — ExternalDNS, `https://eks.<domain>` live
- [ ] Task 5 — CI/CD pipelines
- [ ] Task 6 — ArgoCD
- [ ] Task 7 — Prometheus/Grafana dashboards
- [ ] Task 8 — Architecture diagram
- [ ] Final: README with screenshots, everything destroyed when not in use
