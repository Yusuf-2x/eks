# Task 1 — AWS Infrastructure with Terraform

## What was built

```
                         Internet
                            │
                     ┌──────┴──────┐
                     │ Internet GW │
┌────────────────────┴─────────────┴──────────────────── VPC 10.0.0.0/16 ┐
│                                                                        │
│  AZ a                                  AZ b                            │
│  ┌──────────────────────┐              ┌──────────────────────┐        │
│  │ PUBLIC 10.0.0.0/20   │              │ PUBLIC 10.0.16.0/20  │        │
│  │  NAT gateway         │              │  (load balancer      │        │
│  │  (load balancer      │              │   lands here in T2)  │        │
│  │   lands here in T2)  │              │                      │        │
│  └──────────┬───────────┘              └──────────────────────┘        │
│             │ outbound only                                            │
│  ┌──────────┴───────────┐              ┌──────────────────────┐        │
│  │ PRIVATE 10.0.128.0/20│              │ PRIVATE 10.0.144.0/20│        │
│  │  EKS node (t3.medium)│              │  EKS node (t3.medium)│        │
│  │  EKS control-plane   │              │  EKS control-plane   │        │
│  │  ENIs                │              │  ENIs                │        │
│  └──────────────────────┘              └──────────────────────┘        │
└────────────────────────────────────────────────────────────────────────┘
   EKS control plane (AWS-managed) ── secrets encrypted with KMS, logs → CloudWatch
   Terraform state → S3 (versioned, encrypted) + DynamoDB lock
```

### Files
| File | What it does |
|---|---|
| `terraform/bootstrap/` | Creates the S3 state bucket + DynamoDB lock table. Run once. |
| `terraform/modules/vpc/` | VPC, 2 public + 2 private subnets, IGW, NAT, route tables, flow logs, subnet tags EKS needs. |
| `terraform/modules/iam/` | `eks-cluster-role` (for EKS) and `eks-node-role` (for worker EC2s: join cluster, CNI, ECR read-only, SSM). |
| `terraform/modules/eks/` | Cluster, KMS key, log group, security groups, hardened launch template, managed node group, add-ons (incl. Pod Identity agent). |
| `terraform/main.tf` | Calls the three modules and wires outputs → inputs. |
| `terraform/versions.tf` | Provider versions + `backend "s3" {}`. |
| `terraform/variables.tf` / `outputs.tf` | Knobs you can change / useful values printed after apply. |

### How each assignment requirement is met
| Requirement | Where |
|---|---|
| EKS cluster, VPC, IAM roles, security groups | `modules/eks`, `modules/vpc`, `modules/iam` |
| Reusable modules | Three modules with their own variables/outputs, called from root |
| Proper state management | S3 backend + DynamoDB locking, bucket versioned/encrypted/private/HTTPS-only |
| Private subnets for EKS, public for load balancing | Nodes + control plane ENIs → `private_subnet_ids`; public subnets tagged `kubernetes.io/role/elb=1` |
| IAM roles for worker nodes | `modules/iam` → `aws_iam_role.node` (only the 4 policies nodes need) |
| SGs limited to required access | Node SG: only node↔node, and control plane → 443/10250/1025-65535. Control plane SG: only 443 from nodes. **No SSH** anywhere (use SSM). Default VPC SG locked down. |

### Security extras (these will help you pass Checkov in Task 5)
- Kubernetes Secrets envelope-encrypted with a KMS key (rotation on)
- All 5 control-plane log types → CloudWatch
- API endpoint access restricted by CIDR (`api_allowed_cidrs`)
- Nodes: IMDSv2 required, encrypted gp3 disks, no public IPs
- VPC flow logs
- `upgrade_policy = STANDARD` so you're never auto-billed for extended support

---

## How to deploy it (step by step)

> Prereqs: tools installed + `aws configure` done (see `PROJECT-PLAN.md` §0). Budget alert set!

### Step 1 — Create the state bucket (once ever)
```powershell
cd ~\OneDrive\Desktop\eks-project\terraform\bootstrap
terraform init
terraform apply          # type 'yes'
```
Note the outputs `state_bucket` and `lock_table`.

### Step 2 — Point the main stack at that bucket
```powershell
cd ..
copy backend.hcl.example backend.hcl
copy terraform.tfvars.example terraform.tfvars
```
Edit `backend.hcl` → put your real bucket name (it contains your account ID).
Optional: in `terraform.tfvars` set `api_allowed_cidrs = ["<your-ip>/32"]` (get it from https://checkip.amazonaws.com).

Check the Kubernetes version is still in **standard** support:
```powershell
aws eks describe-cluster-versions --query "clusterVersions[?versionStatus=='STANDARD_SUPPORT'].clusterVersion"
```
If `1.35` isn't listed, set `cluster_version` in `terraform.tfvars` to one that is.

### Step 3 — Plan and apply (~15 minutes)
```powershell
terraform init -backend-config=backend.hcl
terraform fmt -check -recursive
terraform validate
terraform plan -out tfplan
terraform apply tfplan
```

### Step 4 — Connect kubectl and verify ✅
```powershell
aws eks update-kubeconfig --region eu-north-1 --name eks-project-cluster
kubectl get nodes                 # 2 nodes, STATUS Ready
kubectl get pods -A               # coredns, aws-node, kube-proxy, eks-pod-identity-agent Running
```
**Screenshot this for your portfolio/README.**

### Step 5 — Tear down when you're finished for the day 💸
```powershell
terraform destroy
```
(The bootstrap bucket stays — it costs pennies. It has `prevent_destroy` on purpose.)

---

## Troubleshooting
| Symptom | Fix |
|---|---|
| `Error: No valid credential sources found` | Run `aws configure` / `aws sso login`. |
| `BucketAlreadyExists` in bootstrap | Someone else has that name — change `name_prefix`. |
| `unsupported Kubernetes version` | Pick a version from the `describe-cluster-versions` command above. |
| `kubectl` says `Unauthorized` | You applied with a different IAM identity than you're using now. The identity that ran `apply` is admin; add others with `aws_eks_access_entry`. |
| Nodes never become Ready | Usually NAT/route issue — check `kubectl get pods -n kube-system` and the node group's health in the console. |
| `Error acquiring the state lock` | A previous run crashed. Make sure nothing is running, then `terraform force-unlock <ID>`. |
| Destroy hangs on subnets/VPC | A load balancer created by Kubernetes (Task 2+) still exists. Always `helm uninstall ingress-nginx` (or delete LoadBalancer Services) **before** `terraform destroy`. |
