# -----------------------------------------------------------------------------
# ADD-ONS MODULE (installed into the cluster with Helm)
#  - kube-prometheus-stack : Prometheus + Grafana (grafana.<domain>)
#  - cert-manager          : Let's Encrypt certificates (DNS-01 in Route 53)
#  - ExternalDNS           : creates Route 53 records for every Ingress host
#  - NGINX Ingress (F5)    : one internet-facing NLB in front of all Ingresses
#  - Argo CD               : argocd.<domain>, deploys the app from Git (k8s/)
#
# Order matters both ways. Install: monitoring CRDs first (the others create
# ServiceMonitors), cert-manager before its ClusterIssuers, the app last.
# Destroy runs in reverse: the app (and its DNS record) goes first, then the
# NGINX Service, so Auto Mode deletes the NLB before the cluster and VPC go.
#
# The community ingress-nginx project was retired in March 2026, so this uses
# F5's maintained NGINX Ingress Controller (nginx/kubernetes-ingress). Same
# Ingress objects; annotations use the nginx.org/ prefix.
# -----------------------------------------------------------------------------

locals {
  argocd_host  = "argocd.${var.domain_name}"
  grafana_host = "grafana.${var.domain_name}"

  # Pinned chart versions: bump deliberately, not on every apply.
  chart_versions = {
    kube_prometheus_stack = "92.17.0"
    cert_manager          = "v1.21.3"
    external_dns          = "1.23.0"
    nginx_ingress         = "2.8.0"
    argo_cd               = "10.11.6"
    argocd_apps           = "2.0.7"
  }

  # Every Ingress gets a Let's Encrypt cert from the same issuer.
  tls_annotations = {
    "cert-manager.io/cluster-issuer" = var.cluster_issuer
  }
}

data "aws_route53_zone" "this" {
  name         = var.domain_name
  private_zone = false
}

# ---------------- Pod Identity roles (Route 53, this zone only) ----------------
module "external_dns_identity" {
  source = "../pod-identity"

  name            = "${var.cluster_name}-external-dns"
  cluster_name    = var.cluster_name
  namespace       = "external-dns"
  service_account = "external-dns"

  policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["route53:ChangeResourceRecordSets", "route53:ListResourceRecordSets", "route53:ListTagsForResources"]
        Resource = data.aws_route53_zone.this.arn
      },
      {
        Effect   = "Allow"
        Action   = ["route53:ListHostedZones"]
        Resource = "*"
      },
    ]
  })
}

module "cert_manager_identity" {
  source = "../pod-identity"

  name            = "${var.cluster_name}-cert-manager"
  cluster_name    = var.cluster_name
  namespace       = "cert-manager"
  service_account = "cert-manager"

  policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Only _acme-challenge TXT records: cert-manager can't touch the real site records.
        Effect   = "Allow"
        Action   = "route53:ChangeResourceRecordSets"
        Resource = data.aws_route53_zone.this.arn
        Condition = {
          "ForAllValues:StringEquals" = { "route53:ChangeResourceRecordSetsRecordTypes" = ["TXT"] }
          "ForAllValues:StringLike"   = { "route53:ChangeResourceRecordSetsNormalizedRecordNames" = ["_acme-challenge.*"] }
        }
      },
      {
        Effect   = "Allow"
        Action   = "route53:ListResourceRecordSets"
        Resource = data.aws_route53_zone.this.arn
      },
      {
        Effect   = "Allow"
        Action   = "route53:GetChange"
        Resource = "arn:aws:route53:::change/*"
      },
    ]
  })
}

# ---------------- Storage ----------------
resource "helm_release" "storage_class" {
  name  = "storage-class"
  chart = "${path.module}/charts/storage-class"
}

# ---------------- Monitoring ----------------
resource "random_password" "grafana_admin" {
  length  = 24
  special = false
}

resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = local.chart_versions.kube_prometheus_stack
  namespace        = "monitoring"
  create_namespace = true
  timeout          = 900

  values = [yamlencode({
    # EKS runs these on the managed control plane (and Auto Mode has no
    # kube-proxy pods), so they can't be scraped; leaving them on only adds
    # permanently-firing "target down" alerts.
    kubeControllerManager = { enabled = false }
    kubeScheduler         = { enabled = false }
    kubeEtcd              = { enabled = false }
    kubeProxy             = { enabled = false }

    # No alert receivers configured yet; saves a pod + volume.
    alertmanager = { enabled = false }

    prometheus = {
      prometheusSpec = {
        # Pick up ServiceMonitors from every chart, not only this release's.
        serviceMonitorSelectorNilUsesHelmValues = false
        podMonitorSelectorNilUsesHelmValues     = false
        ruleSelectorNilUsesHelmValues           = false

        retention = "7d"
        resources = { requests = { cpu = "200m", memory = "1Gi" } }

        storageSpec = {
          volumeClaimTemplate = {
            spec = {
              storageClassName = "gp3"
              accessModes      = ["ReadWriteOnce"]
              resources        = { requests = { storage = "10Gi" } }
            }
          }
        }
        # Delete the EBS volume with the release, so `terraform destroy`
        # doesn't leave orphaned volumes behind.
        persistentVolumeClaimRetentionPolicy = {
          whenDeleted = "Delete"
          whenScaled  = "Retain"
        }
      }
    }

    grafana = {
      ingress = {
        enabled          = true
        ingressClassName = "nginx"
        annotations      = local.tls_annotations
        hosts            = [local.grafana_host]
        tls              = [{ secretName = "grafana-tls", hosts = [local.grafana_host] }]
      }
    }
  })]

  set_sensitive = [{
    name  = "grafana.adminPassword"
    value = random_password.grafana_admin.result
  }]

  depends_on = [helm_release.storage_class]
}

# ---------------- cert-manager ----------------
resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = local.chart_versions.cert_manager
  namespace        = "cert-manager"
  create_namespace = true

  values = [yamlencode({
    crds           = { enabled = true }
    serviceAccount = { name = "cert-manager" }
    prometheus     = { servicemonitor = { enabled = true } }
  })]

  depends_on = [
    module.cert_manager_identity,
    helm_release.kube_prometheus_stack, # ServiceMonitor CRD
  ]
}

resource "helm_release" "cluster_issuers" {
  name      = "cluster-issuers"
  chart     = "${path.module}/charts/cluster-issuers"
  namespace = "cert-manager"

  values = [yamlencode({
    region       = var.region
    hostedZoneID = data.aws_route53_zone.this.zone_id
    dnsZone      = var.domain_name
  })]

  depends_on = [helm_release.cert_manager]
}

# ---------------- ExternalDNS ----------------
resource "helm_release" "external_dns" {
  name             = "external-dns"
  repository       = "https://kubernetes-sigs.github.io/external-dns/"
  chart            = "external-dns"
  version          = local.chart_versions.external_dns
  namespace        = "external-dns"
  create_namespace = true

  values = [yamlencode({
    provider       = { name = "aws" }
    serviceAccount = { create = true, name = "external-dns" }
    env            = [{ name = "AWS_DEFAULT_REGION", value = var.region }]

    sources       = ["ingress"]
    domainFilters = [var.domain_name]
    extraArgs     = ["--zone-id-filter=${data.aws_route53_zone.this.zone_id}", "--aws-zone-type=public"]

    # sync = also deletes records when their Ingress is deleted. Only records
    # with this owner's TXT marker are ever touched.
    policy             = "sync"
    txtOwnerId         = var.cluster_name
    triggerLoopOnEvent = true

    serviceMonitor = { enabled = true }
  })]

  depends_on = [
    module.external_dns_identity,
    helm_release.kube_prometheus_stack,
  ]
}

# ---------------- NGINX Ingress Controller (F5) ----------------
resource "helm_release" "nginx_ingress" {
  name             = "nginx-ingress"
  repository       = "oci://ghcr.io/nginx/charts"
  chart            = "nginx-ingress"
  version          = local.chart_versions.nginx_ingress
  namespace        = "nginx-ingress"
  create_namespace = true

  values = [yamlencode({
    controller = {
      replicaCount        = 2
      podDisruptionBudget = { enabled = true, minAvailable = 1 }

      ingressClass = { name = "nginx", create = true, setAsDefaultIngress = true }

      service = {
        # Auto Mode's built-in load balancer controller makes an NLB in the
        # public subnets. Its default scheme is internal, hence the annotation.
        loadBalancerClass = "eks.amazonaws.com/nlb"
        annotations = {
          "service.beta.kubernetes.io/aws-load-balancer-scheme" = "internet-facing"
        }
      }

      config = {
        entries = {
          "server-tokens"           = "False"
          "hsts"                    = "True"
          "hsts-max-age"            = "31536000"
          "hsts-include-subdomains" = "False"
        }
      }
    }

    prometheus = {
      create         = true
      service        = { create = true }
      serviceMonitor = { create = true }
    }
  })]

  depends_on = [helm_release.kube_prometheus_stack]
}

# ---------------- Argo CD ----------------
resource "helm_release" "argo_cd" {
  name             = "argo-cd"
  repository       = "oci://ghcr.io/argoproj/argo-helm"
  chart            = "argo-cd"
  version          = local.chart_versions.argo_cd
  namespace        = "argocd"
  create_namespace = true

  values = [yamlencode({
    global = { domain = local.argocd_host }

    # TLS ends at NGINX; Argo CD serves plain HTTP inside the cluster.
    # Use `argocd login --grpc-web argocd.<domain>` for the CLI.
    configs = { params = { "server.insecure" = true } }

    dex = { enabled = false } # no SSO; log in as admin

    server = {
      ingress = {
        enabled          = true
        ingressClassName = "nginx"
        annotations      = local.tls_annotations
        tls              = true # secret argocd-server-tls, filled by cert-manager
      }
      metrics = { enabled = true, serviceMonitor = { enabled = true } }
    }
    controller = { metrics = { enabled = true, serviceMonitor = { enabled = true } } }
    repoServer = { metrics = { enabled = true, serviceMonitor = { enabled = true } } }
  })]

  depends_on = [helm_release.kube_prometheus_stack]
}

# The app itself: Argo CD keeps the cluster in sync with k8s/ in Git.
# The finalizer makes Argo CD delete the app's resources (and so ExternalDNS
# its DNS record) when this is destroyed, instead of leaving them behind.
resource "helm_release" "argocd_apps" {
  name       = "argocd-apps"
  repository = "oci://ghcr.io/argoproj/argo-helm"
  chart      = "argocd-apps"
  version    = local.chart_versions.argocd_apps
  namespace  = "argocd"

  values = [yamlencode({
    applications = {
      (var.app_name) = {
        namespace  = "argocd"
        finalizers = ["resources-finalizer.argocd.argoproj.io"]
        project    = "default"
        source = {
          repoURL        = var.gitops_repo_url
          targetRevision = var.gitops_revision
          path           = var.gitops_path
        }
        destination = {
          server    = "https://kubernetes.default.svc"
          namespace = var.app_namespace
        }
        syncPolicy = {
          automated = { prune = true, selfHeal = true }
          retry     = { limit = 10, backoff = { duration = "10s", factor = 2, maxDuration = "5m" } }
        }
      }
    }
  })]

  # Everything the app needs to be reachable, so destroy removes the app first.
  depends_on = [
    helm_release.argo_cd,
    helm_release.nginx_ingress,
    helm_release.external_dns,
    helm_release.cluster_issuers,
  ]
}
