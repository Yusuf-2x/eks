# EKS Project — 2048 on Amazon EKS

Production-style deployment of a static web app (the 2048 game) on Amazon EKS,
with Terraform, GitHub Actions, ArgoCD, NGINX Ingress, cert-manager, ExternalDNS,
Prometheus and Grafana.

Target URL: `https://eks.<your-domain>`

| Doc | Purpose |
|---|---|
| [PROJECT-PLAN.md](PROJECT-PLAN.md) | Everything you need to know: setup, costs, all 8 tasks, progress tracker |
| [docs/TASK-1-GUIDE.md](docs/TASK-1-GUIDE.md) | What Task 1 built and how to deploy it |
| [docs/CONTAINER-GUIDE.md](docs/CONTAINER-GUIDE.md) | The hardened app image: security choices, build, run, scan |

## Status
- ✅ Task 1 — Terraform: VPC, IAM, EKS, remote state (code complete, validated)
- ✅ App container — non-root, read-only, strict CSP; Trivy/Checkov clean
- ⏳ Tasks 2–8 — see the plan

## Quick start
```bash
cd terraform/bootstrap && terraform init && terraform apply
cd .. && cp backend.hcl.example backend.hcl   # fill in bucket name
terraform init -backend-config=backend.hcl && terraform apply
aws eks update-kubeconfig --region eu-north-1 --name eks-project-cluster
kubectl get nodes
```

> ⚠️ Running this costs ~$0.27/hour. `terraform destroy` when done.
