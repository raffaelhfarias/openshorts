# ============================================================
# OpenShorts - All-in-One Self-Hosted
# FastAPI + Dashboard + Remotion Renderer + Nginx
# ============================================================


# ============================================================
# 1. FRONTEND BUILD
# ============================================================
FROM node:18-alpine AS frontend-builder

WORKDIR /build/dashboard

COPY dashboard/package.json dashboard/package-lock.json* ./
RUN npm install

COPY dashboard/ ./

# Empty = same-origin.
# Browser calls /api/... on the same domain served by nginx.
ARG VITE_API_URL=""
ENV VITE_API_URL=${VITE_API_URL}

ARG VITE_OPENPANEL_API_URL=""
ENV VITE_OPENPANEL_API_URL=${VITE_OPENPANEL_API_URL}

ARG VITE_OPENPANEL_CLIENT_ID=""
ENV VITE_OPENPANEL_CLIENT_ID=${VITE_OPENPANEL_CLIENT_ID}

RUN npm run build


# ============================================================
# 2. PYTHON DEPENDENCIES
# ============================================================
FROM python:3.11-slim AS python-builder

WORKDIR /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt requirements-billing.txt ./

RUN python -m venv /opt/venv

ENV PATH="/opt/venv/bin:${PATH}"

RUN pip install --upgrade pip \
    && pip install --no-cache-dir -r requirements.txt \
    && pip install --no-cache-dir -r requirements-billing.txt

# Optional GPU dependencies.
ARG GPU=0

RUN if [ "$GPU" = "1" ]; then \
      pip install --no-cache-dir \
        "nvidia-cublas-cu12<13" \
        "nvidia-cudnn-cu12>=9,<10" \
        onnx-asr \
        onnxruntime-gpu; \
    fi


# ============================================================
# 3. FINAL IMAGE
# ============================================================
FROM python:3.11-slim

WORKDIR /app


# ============================================================
# 4. SYSTEM DEPENDENCIES
# ============================================================
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ffmpeg \
        curl \
        libgl1 \
        libglib2.0-0 \
        libsm6 \
        libxext6 \
        libxrender1 \
        nodejs \
        npm \
        git \
        fontconfig \
        fonts-liberation \
        fonts-noto-color-emoji \
        chromium \
        nginx \
        supervisor \
    && rm -rf /var/lib/apt/lists/*


# ============================================================
# 5. DENO
# ============================================================
COPY --from=denoland/deno:bin /deno /usr/local/bin/deno


# ============================================================
# 6. PYTHON ENVIRONMENT
# ============================================================
COPY --from=python-builder /opt/venv /opt/venv

ENV PATH="/opt/venv/bin:${PATH}"
ENV PYTHONUNBUFFERED=1

ENV LD_LIBRARY_PATH="/opt/venv/lib/python3.11/site-packages/nvidia/cublas/lib:/opt/venv/lib/python3.11/site-packages/nvidia/cudnn/lib:/opt/venv/lib/python3.11/site-packages/nvidia/cuda_runtime/lib:/opt/venv/lib/python3.11/site-packages/nvidia/cu13/lib"

ENV NVIDIA_DRIVER_CAPABILITIES="compute,video,utility"


# ============================================================
# 7. BACKEND SOURCE
# ============================================================
WORKDIR /app

COPY . .


# ============================================================
# 8. yt-dlp + BGUTIL
# ============================================================
RUN git clone --depth 1 \
      https://github.com/Brainicism/bgutil-ytdlp-pot-provider \
      /opt/bgutil-provider \
    && cd /opt/bgutil-provider/server \
    && npm install --no-audit --no-fund \
    && npx tsc \
    && npm cache clean --force

ENV BGUTIL_SCRIPT_PATH="/opt/bgutil-provider/server/build/generate_once.js"

RUN pip install --upgrade --pre --no-cache-dir \
      "yt-dlp[default]" \
      bgutil-ytdlp-pot-provider


# ============================================================
# 9. RENDER SERVICE
# ============================================================
WORKDIR /renderer

COPY render-service/package.json ./

RUN npm install

COPY render-service/tsconfig.json ./
COPY render-service/src/ ./src/

RUN npm run build


# ============================================================
# 10. REMOTION
#
# IMPORTANT:
# This intentionally follows the original render-service
# Dockerfile behavior.
#
# Do NOT copy remotion/package-lock.json here.
# ============================================================
WORKDIR /app/remotion

COPY remotion/package.json ./

RUN npm install

COPY remotion/tsconfig.json ./
COPY remotion/src/ ./src/
COPY remotion/public/ ./public/


# ============================================================
# 11. RENDERER CONFIGURATION
# ============================================================
ENV PUPPETEER_EXECUTABLE_PATH="/usr/bin/chromium"

ENV REMOTION_BUNDLE_PATH="/app/remotion"

ENV OUTPUT_DIR="/app/output"

ENV PORT="3100"

# Original Docker Compose default:
# http://renderer:3100
#
# In this all-in-one container, backend and renderer share
# localhost.
ENV RENDER_SERVICE_URL="http://127.0.0.1:3100"


# ============================================================
# 12. FRONTEND
# ============================================================
RUN rm -rf /usr/share/nginx/html/*

COPY --from=frontend-builder \
     /build/dashboard/dist/ \
     /usr/share/nginx/html/


# ============================================================
# 13. FONTS
# ============================================================
WORKDIR /app

RUN mkdir -p /usr/local/share/fonts/openshorts \
    && cp fonts/*.ttf /usr/local/share/fonts/openshorts/ \
    && cp fonts/openshorts-fontmap.conf \
       /etc/fonts/conf.d/60-openshorts.conf \
    && fc-cache -f


# ============================================================
# 14. APPLICATION DIRECTORIES
# ============================================================
RUN mkdir -p \
      /app/uploads \
      /app/output \
      /app/.cache/huggingface \
      /tmp/Ultralytics


# ============================================================
# 15. APPLICATION USER
# ============================================================
RUN groupadd -r appuser \
    && useradd \
       -r \
       -g appuser \
       -d /app \
       -s /usr/sbin/nologin \
       appuser

RUN chown -R appuser:appuser \
      /app \
      /renderer \
      /tmp/Ultralytics


# ============================================================
# 16. PRE-DOWNLOAD YOLO MODEL
# ============================================================
USER appuser

WORKDIR /app

RUN python -c "from ultralytics import YOLO; YOLO('yolov8n.pt')"

USER root


# ============================================================
# 17. NGINX CONFIGURATION
# ============================================================
RUN rm -f \
      /etc/nginx/sites-enabled/default \
      /etc/nginx/conf.d/default.conf

RUN cat > /etc/nginx/conf.d/openshorts.conf <<'EOF'
server {
    listen 80 default_server;
    server_name _;

    root /usr/share/nginx/html;
    index index.html;

    # Video uploads can be large.
    client_max_body_size 2G;


    # ========================================================
    # FASTAPI
    #
    # IMPORTANT:
    # proxy_pass has NO trailing slash.
    #
    # /api/process
    # becomes
    # http://127.0.0.1:8000/api/process
    # ========================================================
    location /api/ {
        proxy_pass http://127.0.0.1:8000;

        proxy_http_version 1.1;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $http_x_forwarded_proto;

        proxy_connect_timeout 60s;
        proxy_send_timeout 3600s;
        proxy_read_timeout 3600s;

        proxy_buffering off;
        proxy_request_buffering off;
    }


    # ========================================================
    # VIDEOS
    # ========================================================
    location /videos/ {
        proxy_pass http://127.0.0.1:8000;

        proxy_http_version 1.1;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $http_x_forwarded_proto;

        proxy_read_timeout 3600s;
        proxy_buffering off;
    }


    # ========================================================
    # THUMBNAILS
    # ========================================================
    location /thumbnails/ {
        proxy_pass http://127.0.0.1:8000;

        proxy_http_version 1.1;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $http_x_forwarded_proto;

        proxy_read_timeout 3600s;
        proxy_buffering off;
    }


    # ========================================================
    # SERVER-RENDERED GALLERY
    # ========================================================
    location = /gallery {
        proxy_pass http://127.0.0.1:8000;

        proxy_http_version 1.1;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $http_x_forwarded_proto;
    }


    # ========================================================
    # SERVER-RENDERED VIDEO PAGE
    # ========================================================
    location /video/ {
        proxy_pass http://127.0.0.1:8000;

        proxy_http_version 1.1;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $http_x_forwarded_proto;
    }


    # ========================================================
    # HEALTHCHECK
    # ========================================================
    location = /health/ready {
        proxy_pass http://127.0.0.1:8000/health/ready;

        proxy_http_version 1.1;

        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $http_x_forwarded_proto;

        access_log off;
    }


    location = /health/live {
        proxy_pass http://127.0.0.1:8000/health/live;

        proxy_http_version 1.1;

        proxy_set_header Host $host;

        access_log off;
    }


    # ========================================================
    # FRONTEND ASSETS
    # ========================================================
    location /assets/ {
        expires 1y;

        add_header Cache-Control "public, immutable";

        try_files $uri =404;
    }


    # ========================================================
    # FRONTEND
    #
    # OpenShorts uses hash routing, so unknown server-side
    # paths should remain real 404 responses.
    # ========================================================
    location / {
        try_files $uri $uri.html $uri/ =404;

        add_header Cache-Control \
          "no-store, must-revalidate" always;

        add_header X-Content-Type-Options \
          "nosniff" always;

        add_header X-Frame-Options \
          "SAMEORIGIN" always;
    }


    # ========================================================
    # 404
    # ========================================================
    error_page 404 /404.html;

    location = /404.html {
        internal;

        add_header Cache-Control \
          "no-store, must-revalidate" always;
    }


    # ========================================================
    # SECURITY HEADERS
    # ========================================================
    add_header X-Content-Type-Options \
      "nosniff" always;

    add_header X-Frame-Options \
      "SAMEORIGIN" always;
}
EOF


# ============================================================
# 18. SUPERVISOR
# ============================================================
RUN cat > /etc/supervisor/conf.d/openshorts.conf <<'EOF'
[supervisord]
nodaemon=true
user=root
logfile=/dev/null
logfile_maxbytes=0
pidfile=/tmp/supervisord.pid


# ============================================================
# FASTAPI
# ============================================================
[program:backend]

directory=/app

command=/opt/venv/bin/uvicorn app:app --host 127.0.0.1 --port 8000 --proxy-headers --forwarded-allow-ips=* --timeout-graceful-shutdown 15

user=appuser

autostart=true
autorestart=true

startsecs=3
startretries=10

stopwaitsecs=30

stopsignal=TERM
stopasgroup=true
killasgroup=true

stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0

stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0

environment=HOME="/app"


# ============================================================
# REMOTION RENDERER
# ============================================================
[program:renderer]

directory=/renderer

command=/usr/bin/node dist/server.js

user=appuser

autostart=true
autorestart=true

# Remotion needs some time to create its webpack bundle.
startsecs=10
startretries=5

stopwaitsecs=30

stopsignal=TERM
stopasgroup=true
killasgroup=true

stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0

stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0

environment=HOME="/app",PORT="3100",OUTPUT_DIR="/app/output",REMOTION_BUNDLE_PATH="/app/remotion",PUPPETEER_EXECUTABLE_PATH="/usr/bin/chromium"


# ============================================================
# NGINX
# ============================================================
[program:nginx]

command=/usr/sbin/nginx -g "daemon off;"

user=root

autostart=true
autorestart=true

startsecs=1
startretries=5

stopsignal=QUIT
stopasgroup=true
killasgroup=true

stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0

stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
EOF


# ============================================================
# 19. HEALTHCHECK
# ============================================================
HEALTHCHECK \
    --interval=10s \
    --timeout=5s \
    --start-period=90s \
    --retries=3 \
    CMD curl -sf http://127.0.0.1:80/health/ready >/dev/null || exit 1


# ============================================================
# 20. PUBLIC PORT
# ============================================================
EXPOSE 80


# ============================================================
# 21. START
# ============================================================
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/supervisord.conf"]
