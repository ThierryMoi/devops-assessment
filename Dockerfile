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

RUN apk update && apk upgrade --no-cache

# Non-root nginx: writable pid, logs, cache and temp paths
RUN mkdir -p /tmp/nginx /tmp/client_body /tmp/proxy /tmp/fastcgi /tmp/uwsgi /tmp/scgi \
    && chown -R nginx:nginx /tmp /var/cache/nginx /var/log/nginx

COPY nginx-main.conf /etc/nginx/nginx.conf
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=builder /app/dist/ /usr/share/nginx/html

RUN chown -R nginx:nginx /usr/share/nginx/html /etc/nginx/conf.d/default.conf

USER nginx

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
    CMD wget -qO- http://localhost:8080/healthz || exit 1

CMD ["nginx", "-g", "daemon off;"]
