# EKS Project — 2048 on Amazon EKS

Production-style deployment of a static web app (the 2048 game) on Amazon EKS Auto Mode,
with Terraform, GitHub Actions, ArgoCD, NGINX Ingress, cert-manager, ExternalDNS,
Prometheus and Grafana.

Target URL: `https://eks.<your-domain>`

| Doc | Purpose |
|---|---|
| [PROJECT-PLAN.md](PROJECT-PLAN.md) | Everything you need to know: setup, costs, all 8 tasks, progress tracker |
| [docs/TASK-1-GUIDE.md](docs/TASK-1-GUIDE.md) | What Task 1 built (EKS Auto Mode) and how to deploy it |
| [docs/REMOTE-STATE.md](docs/REMOTE-STATE.md) | The hand-made S3 state bucket and how the stacks use it |
| [docs/CONTAINER-GUIDE.md](docs/CONTAINER-GUIDE.md) | The hardened app image: security choices, build, run, scan, push |

## Status
- ✅ Task 1 — Terraform: VPC, IAM, EKS Auto Mode in 4 modules; remote state in a hand-made S3 bucket (code complete, plan passes, not applied yet)
- ✅ App container — non-root, read-only, strict CSP; Trivy/Checkov clean
- ✅ ECR — `eks-2048` repo in eu-west-2 (immutable tags, scan on push, KMS); image `ec0b220` pushed
- ⏳ Tasks 2–8 — see the plan

## Quick start
```bash
# once: create the state bucket by hand -> docs/REMOTE-STATE.md
cd terraform/ecr && cp backend.hcl.example backend.hcl          # fill in account ID
terraform init -backend-config=backend.hcl && terraform apply   # ECR repo (long-lived)
cd .. && cp backend.hcl.example backend.hcl                     # fill in account ID
cp terraform.tfvars.example terraform.tfvars                    # set api_allowed_cidrs to your IP
terraform init -backend-config=backend.hcl && terraform apply   # VPC + IAM + EKS Auto Mode
aws eks update-kubeconfig --region eu-west-2 --name eks-project-cluster
kubectl get nodepools
```

> ⚠️ The cluster costs ~$0.15/hour empty and more once apps run. `terraform destroy` when done.
