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

# Custom nginx config for SPA routing
COPY nginx.conf /etc/nginx/conf.d/default.conf

# Copy built static files
COPY --from=builder /app/dist/ /usr/share/nginx/html

# Run as non-root for security
RUN chown -R nginx:nginx /usr/share/nginx/html \
    && chown -R nginx:nginx /var/cache/nginx \
    && chown -R nginx:nginx /var/log/nginx \
    && touch /var/run/nginx.pid \
    && chown nginx:nginx /var/run/nginx.pid

USER nginx

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
    CMD wget -qO- http://localhost:8080/ || exit 1
