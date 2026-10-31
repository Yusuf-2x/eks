# Containerising the app (secure image)

## What was built

```
 app/  ──docker build──►  eks-2048 image (~9 MB)
                          ├─ nginx 1.30.6 on Alpine 3.24 (slim), pinned by digest
                          ├─ runs as uid 101 (not root), listens on 8080
                          ├─ /etc/nginx/nginx.conf   root-owned, read-only
                          └─ /usr/share/nginx/html/  game files, root-owned, read-only
```

### Files
| File | What it does |
|---|---|
| `app/Dockerfile` | Two-stage build: stage 1 gathers only the files the site needs and makes them read-only; stage 2 is the hardened nginx runtime. |
| `app/nginx.conf` | Replaces nginx's default config: security headers, GET/HEAD only, `/healthz`, no dotfiles, writes only to `/tmp`. |
| `app/.dockerignore` | Allow-list of what may enter the build. Everything else (secrets, `.git`, notes) is never sent to Docker. |

### Security choices and why
| Choice | Why it matters |
|---|---|
| `nginx-unprivileged` base, `USER 101:101` | A break-in lands as a normal user, not root. Numeric uid lets Kubernetes `runAsNonRoot` verify it. |
| Listens on **8080**, not 80 | Ports below 1024 need root or extra Linux capabilities. 8080 needs neither. |
| `-slim` variant | Fewer packages (no curl, no extra nginx modules) → less for an attacker to use and fewer CVEs. |
| Base pinned **by digest** (`@sha256:…`) | A tag can be re-pushed. A digest always means the exact same image. |
| `apk upgrade` at build time | Picks up Alpine security fixes released since the base image was published. |
| Config + site files owned by **root**, mode `0444` | The base image lets the nginx user rewrite its own config. We remove that, so a compromised nginx can't change how it runs or deface the site. |
| Works with a **read-only root filesystem** | Everything nginx writes (pid, temp files) goes to `/tmp`, so the rest can be locked. |
| Entrypoint scripts removed, `ENTRYPOINT ["nginx"]` | No shell scripts run at startup and nothing tries to rewrite config. Less code = less risk. |
| `server_tokens off` | Hides the nginx version from attackers looking for known bugs. |
| Only `GET`/`HEAD` (others → `405`) | It's a static site. There is nothing to POST/PUT/DELETE. |
| `client_max_body_size 1k` + short timeouts | Rejects uploads and drops slow "slowloris"-style clients. |
| Dotfiles → `404` | `.git`, `.env` etc. can never be served, even if one slips into the image. |
| Strict **Content-Security-Policy** | The browser only runs scripts/styles/fonts from this site. Injected scripts are blocked. Works because the game has no inline code. |
| `X-Frame-Options DENY`, `frame-ancestors 'none'` | Stops other sites embedding the game in a frame (clickjacking). |
| `nosniff`, `Referrer-Policy`, `Permissions-Policy`, COOP/CORP | Browser hardening: no MIME guessing, no referrer leaks, no camera/mic/location access, isolated from other origins. |
| `/healthz` + `HEALTHCHECK` | Docker (and later Kubernetes probes) can tell if nginx is actually serving. |
| **HSTS not set here** | Browsers ignore HSTS over plain HTTP. It gets added at the ingress once HTTPS exists (Task 3). |

## How to build and run it

```powershell
cd eks-project
docker build -t eks-2048 app
```

Run it with the same lockdown it will get in production:

```powershell
docker run --rm -p 8080:8080 `
  --read-only --tmpfs /tmp:rw,noexec,nosuid,size=16m `
  --cap-drop ALL --security-opt no-new-privileges:true `
  eks-2048
```

Open http://localhost:8080 and play. `Ctrl+C` to stop.

## How to check it's secure

```powershell
trivy image eks-2048                                          # OS package CVEs
trivy config app/                                             # Dockerfile mistakes
checkov -f app/Dockerfile --framework dockerfile --compact    # Dockerfile best practice
curl.exe -I http://localhost:8080/                            # security headers present, "Server: nginx" with no version
curl.exe -X POST http://localhost:8080/                       # 405
```

Results on 2026-10-31: Trivy **0 vulnerabilities**, Trivy config **0 misconfigurations**, Checkov **44 passed / 0 failed**.

## Pushing to ECR

The registry is `terraform/ecr` → repo **`eks-2048`** in **eu-west-2**:
`590184076390.dkr.ecr.eu-west-2.amazonaws.com/eks-2048`

| Setting | Why |
|---|---|
| **Immutable tags** | Once `ec0b220` is pushed, nobody can push a different image under that tag. What's running is what was scanned. |
| **Scan on push** | ECR checks every new image for known CVEs (free basic scanning). |
| **KMS encryption** | Images encrypted at rest (AWS-managed key, no monthly fee). |
| **Lifecycle policy** | Keeps the newest 20 images, deletes untagged ones after 7 days. |
| **`force_delete = false`** | The repo can't be deleted while it still holds images. |
| **Separate stack** | `terraform destroy` on the cluster never touches your images. |

Tag = the git commit the app was built from, so you always know what code an image contains.

```powershell
cd eks-project
$REPO = "590184076390.dkr.ecr.eu-west-2.amazonaws.com/eks-2048"
$TAG  = git log -1 --format=%h -- app          # commit that last changed app/
docker build --platform linux/amd64 --provenance=false --sbom=false -t "${REPO}:${TAG}" app
aws ecr get-login-password --region eu-west-2 | docker login --username AWS --password-stdin 590184076390.dkr.ecr.eu-west-2.amazonaws.com
docker push "${REPO}:${TAG}"
aws ecr describe-image-scan-findings --region eu-west-2 --repository-name eks-2048 --image-id imageTag=$TAG
```

`--provenance=false --sbom=false` pushes one plain image instead of an image index with attestations, which keeps ECR scanning and the lifecycle policy simple. In CI (Task 5) you can add an SBOM and image signing instead.

Pushed so far: `ec0b220` → `sha256:75d09d91b5399209e764fc9e8cbfd5ab9f565a6be1631f7dbc079b1ccbd06578` (ECR scan: 0 findings).

## Keeping it secure

- **New nginx/Alpine release:** bump the tag *and* digest in the `FROM` line. Get the digest with
  `docker buildx imagetools inspect nginxinc/nginx-unprivileged:<tag>`.
- **Changed the game to use a CDN, inline `<script>`, or `style="..."`?** The CSP will block it. Either move it to a file or add that source to the CSP in `app/nginx.conf`.
- **Adding `add_header` inside a `location {}` block?** nginx then drops *all* the server-level security headers for that location. Repeat them, or don't add headers there.
