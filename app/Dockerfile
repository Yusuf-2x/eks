# 2048 game served by NGINX, hardened for production.
# Build:  docker build -t eks-2048 app/
# Run:    docker run --rm -p 8080:8080 --read-only --tmpfs /tmp --cap-drop ALL \
#           --security-opt no-new-privileges eks-2048

# Base image pinned by digest (not just tag) so a re-pushed tag can't change what we build.
# nginx-unprivileged = official NGINX image that runs as uid 101 and listens on 8080.
# "slim" = fewer packages (no curl, no extra modules) -> smaller attack surface.
FROM nginxinc/nginx-unprivileged:1.30.6-alpine3.24-slim@sha256:5d8bb9437d74a600ec5dbf90c035451c724dc33eac8d3a71078f6f8612c345f6 AS base

# ---- Stage 1: collect only the files the site needs, made read-only ----
FROM base AS site
USER root
COPY index.html favicon.ico LICENSE.txt /site/
COPY js/ /site/js/
COPY meta/ /site/meta/
COPY style/main.css /site/style/
COPY style/fonts/ /site/style/fonts/
RUN find /site -type d -exec chmod 0555 {} + \
 && find /site -type f -exec chmod 0444 {} +

# ---- Stage 2: runtime image ----
FROM base

LABEL org.opencontainers.image.title="eks-2048" \
      org.opencontainers.image.description="2048 game served by hardened NGINX" \
      org.opencontainers.image.licenses="MIT"

USER root
# - apk upgrade: pick up Alpine security fixes released after the base image was built
# - remove the entrypoint scripts (they try to rewrite config at startup) and default site
# - the base image lets the nginx user WRITE its own config; make it root-owned and read-only
#   so a compromised nginx process can't change how it runs
RUN apk upgrade --no-cache \
 && rm -rf /docker-entrypoint.sh /docker-entrypoint.d /etc/nginx/conf.d /usr/share/nginx/html/* \
 && chown -R root:root /etc/nginx /var/cache/nginx \
 && chmod -R go-w /etc/nginx /var/cache/nginx

COPY --chmod=0444 nginx.conf /etc/nginx/nginx.conf
COPY --from=site /site/ /usr/share/nginx/html/

# Numeric uid so Kubernetes "runAsNonRoot" can verify it without looking up names
USER 101:101
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD ["wget", "-q", "--spider", "http://127.0.0.1:8080/healthz"]

# Run nginx directly (no shell wrapper); base image already sets STOPSIGNAL SIGQUIT for graceful stop
ENTRYPOINT ["nginx"]
CMD ["-g", "daemon off;"]
