# ============================================================
# Stage 1 — Build Angular 7 application
# Angular 7.2 requires Node 10.x (incompatible with Node 14+)
# ============================================================
FROM node:10-alpine AS builder

WORKDIR /app

# Dependencies first — leverage Docker layer caching
COPY package.json package-lock.json ./
RUN npm ci --no-audit

# Copy source and build for production
COPY . .
RUN npx ng build --prod

# ============================================================
# Stage 2 — Production image with Nginx
# Only the static assets from dist/ are copied
# Final image: ~25MB vs ~400MB+ with node
# ============================================================
FROM nginx:1.27-alpine

# FIX: apk upgrade doit etre ici (stage final), pas dans le
# stage builder — Trivy et Harbor ne voient que cette image,
# le stage builder est jete apres le COPY --from=builder
RUN apk update && apk upgrade --no-cache

# Custom nginx config for SPA routing
COPY nginx.conf /etc/nginx/conf.d/default.conf

# Copy built static files
COPY --from=builder /app/dist/ /usr/share/nginx/html

# Non-root nginx: pid + temp dirs must be writable by UID 101
RUN chown -R nginx:nginx /usr/share/nginx/html \
    && chown -R nginx:nginx /var/cache/nginx \
    && chown -R nginx:nginx /var/log/nginx \
    && mkdir -p /tmp/nginx /tmp/client_body /tmp/proxy /tmp/fastcgi /tmp/uwsgi /tmp/scgi \
    && chown -R nginx:nginx /tmp \
    && sed -i 's|pid /run/nginx.pid;|pid /tmp/nginx/nginx.pid;|' /etc/nginx/nginx.conf

USER nginx

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
    CMD wget -qO- http://localhost:8080/ || exit 1