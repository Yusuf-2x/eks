# Task 1 — AWS Infrastructure with Terraform (EKS Auto Mode)

## What was built

```
                         Internet
                            │
                     ┌──────┴──────┐
                     │ Internet GW │
┌────────────────────┴─────────────┴──────────────────── VPC 10.0.0.0/16 ┐
│                                                                        │
│  eu-west-2a                            eu-west-2b                      │
│  ┌──────────────────────┐              ┌──────────────────────┐        │
│  │ PUBLIC 10.0.0.0/20   │              │ PUBLIC 10.0.16.0/20  │        │
│  │  NAT gateway         │              │  (load balancers     │        │
│  │  (load balancers     │              │   land here in T2)   │        │
│  │   land here in T2)   │              │                      │        │
│  └──────────┬───────────┘              └──────────────────────┘        │
│             │ outbound only                                            │
│  ┌──────────┴───────────┐              ┌──────────────────────┐        │
│  │ PRIVATE 10.0.128.0/20│              │ PRIVATE 10.0.144.0/20│        │
│  │  Auto Mode nodes     │              │  Auto Mode nodes     │        │
│  │  (appear when pods   │              │                      │        │
│  │   need them)         │              │                      │        │
│  │  control-plane ENIs  │              │  control-plane ENIs  │        │
│  └──────────────────────┘              └──────────────────────┘        │
└────────────────────────────────────────────────────────────────────────┘
   EKS control plane (AWS-managed) ── secrets encrypted with KMS, logs → CloudWatch
   Kubernetes API reachable only from api_allowed_cidrs (your IP)
   Terraform state → S3 bucket made by hand (docs/REMOTE-STATE.md), locked with use_lockfile
```

### What "Auto Mode" means
With classic EKS you manage node groups, launch templates and add-ons yourself. With **EKS Auto Mode**,
AWS does that:

- **Compute:** AWS launches EC2 nodes when pods need them and removes them when they don't (Karpenter under the hood).
  Two built-in node pools: `general-purpose` (your apps) and `system` (critical add-ons).
- **Built-in add-ons:** VPC CNI, CoreDNS, kube-proxy, EBS CSI driver (`storage_config`),
  AWS Load Balancer Controller (`kubernetes_network_config`) and the Pod Identity agent all come built in. Nothing to install or upgrade.
- **Hardened nodes:** Bottlerocket OS, read-only root filesystem, IMDSv2 only, encrypted volumes, no SSH/SSM,
  and every node is replaced at least every 21 days so it stays patched.

### Files
| File | What it does |
|---|---|
| `terraform/modules/vpc/` | VPC, 2 public + 2 private subnets, IGW, NAT, route tables, flow logs, subnet tags for load balancers. |
| `terraform/modules/iam/` | `eks-cluster-role` (EKS + the 4 Auto Mode policies) and `eks-node-role` (only join cluster + pull from ECR). |
| `terraform/modules/eks/` | Auto Mode cluster, KMS key for Secrets, control-plane log group, admin access entries. |
| `terraform/modules/ecr/` | Hardened ECR repository (used by the separate `terraform/ecr` stack). |
| `terraform/main.tf` | Calls the vpc, iam and eks modules and wires outputs → inputs. |
| `terraform/versions.tf` | Provider versions + `backend "s3" {}`. |
| `terraform/variables.tf` / `outputs.tf` | Knobs you can change / useful values printed after apply. |
| `terraform/ecr/` | Separate, long-lived stack for the image registry (not destroyed with the cluster). |

### How each assignment requirement is met
| Requirement | Where |
|---|---|
| EKS cluster, VPC, IAM roles, security groups | `modules/eks` (Auto Mode), `modules/vpc`, `modules/iam` |
| Reusable modules | Four modules (`vpc`, `iam`, `eks`, `ecr`) with their own variables/outputs |
| Proper state management | S3 backend (hand-made bucket: versioned, encrypted, private, HTTPS-only) with S3 native locking |
| Private subnets for EKS, public for load balancing | Nodes + control-plane ENIs → private subnets; public subnets tagged `kubernetes.io/role/elb=1` |
| IAM roles for worker nodes | `modules/iam` → `aws_iam_role.node`: only `AmazonEKSWorkerNodeMinimalPolicy` + `AmazonEC2ContainerRegistryPullOnly` |
| SGs limited to required access | Auto Mode attaches EKS's cluster security group (control plane ↔ nodes only). No SSH anywhere. Default VPC SG locked down. |

### Security extras (these will help you pass Checkov in Task 5)
- Kubernetes API endpoint limited to `api_allowed_cidrs`. It's required, and `0.0.0.0/0` is rejected.
- Kubernetes Secrets envelope-encrypted with a KMS key (rotation on). The cluster role may use only that key.
- All 5 control-plane log types → CloudWatch.
- Admins granted explicitly with EKS access entries (you, plus anyone in `cluster_admin_arns`). No hidden "creator is admin".
- Hardened Auto Mode nodes (see above). VPC flow logs.
- `upgrade_policy = STANDARD`, so you're never auto-billed for extended support.
- Checkov: 80 passed, 0 failed. Trivy: 0 misconfigurations. The few accepted findings have a reason written next to them in the code.

---

## How to deploy it (step by step)

> Prereqs: tools installed + `aws configure` done (see `PROJECT-PLAN.md` §0). Budget alert set!

### Step 1 — State bucket (once ever)
Already created. For a new account, follow [REMOTE-STATE.md](REMOTE-STATE.md).

### Step 2 — Local settings
```powershell
cd ~\OneDrive\Desktop\eks-project\terraform
copy backend.hcl.example backend.hcl            # put your account ID in the bucket name
copy terraform.tfvars.example terraform.tfvars  # set api_allowed_cidrs to YOUR IP
curl.exe https://checkip.amazonaws.com          # your IP -> api_allowed_cidrs = ["x.x.x.x/32"]
```
Both files are gitignored.

Check the Kubernetes version is still in **standard** support:
```powershell
aws eks describe-cluster-versions --query "clusterVersions[?status=='STANDARD_SUPPORT'].clusterVersion"
```
If `1.37` isn't listed, set `cluster_version` in `terraform.tfvars` to one that is.

### Step 3 — Plan and apply (~15 minutes)
```powershell
terraform init -backend-config=backend.hcl
terraform fmt -check -recursive
terraform validate
terraform plan -out tfplan        # expect: 39 to add
terraform apply tfplan
```

### Step 4 — Connect kubectl and verify ✅
```powershell
aws eks update-kubeconfig --region eu-west-2 --name eks-project-cluster
kubectl get nodepools             # general-purpose and system, READY True
kubectl get nodes                 # may be EMPTY: Auto Mode only adds nodes when pods need them
kubectl run hello --image=public.ecr.aws/docker/library/busybox:stable --restart=Never -- sleep 120
kubectl get nodes -w              # a node appears within ~1 minute -> Auto Mode works
kubectl delete pod hello          # node is removed again after a short while
```
**Screenshot this for your portfolio/README.**

### Step 5 — Tear down when you're finished for the day 💸
```powershell
terraform destroy
```
The state bucket and the ECR repo (separate stack) are not touched.

---

## Troubleshooting
| Symptom | Fix |
|---|---|
| `Error: No valid credential sources found` | Run `aws configure`. Check `aws sts get-caller-identity` shows account `590184076390`. |
| `No value for required variable "api_allowed_cidrs"` | Create `terraform.tfvars` (Step 2). |
| `kubectl` times out | Your IP changed. Update `api_allowed_cidrs` in `terraform.tfvars` and `terraform apply`. |
| `unsupported Kubernetes version` | Pick a version from the `describe-cluster-versions` command above. |
| `kubectl` says `Unauthorized` | You're using a different IAM identity than the one that ran `apply`. Add it to `cluster_admin_arns` and apply. |
| Pods stay `Pending`, no node appears | `kubectl get events -A`. Usually a NAT/route problem or the EC2 vCPU quota. Check `kubectl get nodeclaims`. |
| `Error acquiring the state lock` | A previous run crashed. Make sure nothing is running, then `terraform force-unlock <ID>`. |
| Destroy hangs on subnets/VPC | A load balancer created by Kubernetes (Task 2+) still exists. Delete LoadBalancer Services / Ingresses (or `helm uninstall`) **before** `terraform destroy`. |
