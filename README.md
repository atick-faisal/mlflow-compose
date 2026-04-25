# MLflow on Dokploy Setup Guide

A complete guide to deploying MLflow with RustFS artifact storage and a shared Postgres backend on a Dokploy-managed VPS.

---

## Prerequisites

- A running Dokploy instance (see the Hetzner + Dokploy guide)
- A domain pointed at your VPS (e.g. `mlflow.yourdomain.com`)
- A shared Postgres service already created in Dokploy

---

## Part 1: DNS

Add an A record on your DNS provider:

| Type | Host | Answer | TTL |
|------|------|--------|-----|
| A | `mlflow.yourdomain.com` | `<VPS_PUBLIC_IP>` | 300 |

Verify propagation:
```bash
dig mlflow.yourdomain.com
```

---

## Part 2: Create the MLflow Database

In Dokploy, go to your project → **Create Service → Database → Postgres** and create a new database named `mlflow`. Note the internal connection string — you'll need the host, port, username, and password.

If you already have a shared Postgres instance, just create a new database inside it named `mlflow`.

---

## Part 3: Create the Repo

Create a new GitHub repo (e.g. `mlflow-compose`) with these two files:

### `docker-compose.yml`

```yaml
volumes:
  storage-data:
  mlflow-auth-data:

services:
  storage:
    image: rustfs/rustfs:1.0.0-alpha.83
    container_name: mlflow-storage
    environment:
      RUSTFS_ADDRESS: :9000
      RUSTFS_SERVER_DOMAINS: mlflow-storage:9000
      RUSTFS_REGION: ${AWS_DEFAULT_REGION:-us-east-1}
      RUSTFS_ACCESS_KEY: ${AWS_ACCESS_KEY_ID}
      RUSTFS_SECRET_KEY: ${AWS_SECRET_ACCESS_KEY}
      RUSTFS_CONSOLE_ENABLE: "true"
    volumes:
      - storage-data:/data
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "curl -sf http://127.0.0.1:9000/health | grep -q '\"status\":\"ok\"'"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 10s

  create-bucket:
    image: amazon/aws-cli:2.33.25
    container_name: mlflow-create-bucket
    depends_on:
      storage:
        condition: service_healthy
    entrypoint: >
      /bin/sh -c "
        set -e;
        echo 'Waiting for S3 gateway getting ready...';
        if aws --endpoint-url=${MLFLOW_S3_ENDPOINT_URL} s3api head-bucket --bucket ${S3_BUCKET} 2>/dev/null; then
          echo 'Bucket ${S3_BUCKET} already exists. Skipping creation.';
        else
          echo 'Creating bucket ${S3_BUCKET}...';
          aws --endpoint-url=${MLFLOW_S3_ENDPOINT_URL} s3api create-bucket --bucket ${S3_BUCKET} --region ${AWS_DEFAULT_REGION};
        fi
      "
    environment:
      AWS_ACCESS_KEY_ID: ${AWS_ACCESS_KEY_ID}
      AWS_SECRET_ACCESS_KEY: ${AWS_SECRET_ACCESS_KEY}
      AWS_DEFAULT_REGION: ${AWS_DEFAULT_REGION:-us-east-1}
      AWS_S3_ADDRESSING_STYLE: path
      MLFLOW_S3_ENDPOINT_URL: ${MLFLOW_S3_ENDPOINT_URL}
      S3_BUCKET: ${S3_BUCKET}
    restart: "no"

  mlflow:
    image: ghcr.io/mlflow/mlflow:v3.11.1-full
    container_name: mlflow-server
    depends_on:
      storage:
        condition: service_healthy
      create-bucket:
        condition: service_completed_successfully
    environment:
      MLFLOW_BACKEND_STORE_URI: postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}
      MLFLOW_S3_ENDPOINT_URL: ${MLFLOW_S3_ENDPOINT_URL}
      MLFLOW_ARTIFACTS_DESTINATION: s3://${S3_BUCKET}
      AWS_ACCESS_KEY_ID: ${AWS_ACCESS_KEY_ID}
      AWS_SECRET_ACCESS_KEY: ${AWS_SECRET_ACCESS_KEY}
      AWS_DEFAULT_REGION: ${AWS_DEFAULT_REGION:-us-east-1}
      MLFLOW_S3_IGNORE_TLS: "true"
      MLFLOW_HOST: ${MLFLOW_HOST:-0.0.0.0}
      MLFLOW_PORT: ${MLFLOW_PORT:-5000}
      MLFLOW_SERVER_ALLOWED_HOSTS: ${MLFLOW_SERVER_ALLOWED_HOSTS:-mlflow.yourdomain.com}
      MLFLOW_SERVER_CORS_ALLOWED_ORIGINS: ${MLFLOW_SERVER_CORS_ALLOWED_ORIGINS:-https://mlflow.yourdomain.com}
      MLFLOW_FLASK_SERVER_SECRET_KEY: ${MLFLOW_FLASK_SERVER_SECRET_KEY}
      MLFLOW_AUTH_CONFIG_PATH: /mlflow/auth/basic_auth.ini
    volumes:
      - mlflow-auth-data:/mlflow/auth
      - ./basic_auth.ini:/mlflow/auth/basic_auth.ini
    command:
      - /bin/bash
      - -c
      - |
        pip install --no-cache-dir 'mlflow[auth]'
        mlflow server \
          --backend-store-uri "postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}" \
          --artifacts-destination "s3://${S3_BUCKET}" \
          --serve-artifacts \
          --host "${MLFLOW_HOST:-0.0.0.0}" \
          --port "${MLFLOW_PORT:-5000}" \
          --app-name basic-auth
    restart: unless-stopped
    healthcheck:
      test:
        [
          "CMD",
          "python",
          "-c",
          "import urllib.request; urllib.request.urlopen('http://localhost:${MLFLOW_PORT:-5000}/health')",
        ]
      interval: 10s
      timeout: 5s
      retries: 30

networks:
  default:
    name: mlflow-network
    external: false
  dokploy-network:
    external: true
```

### `basic_auth.ini`

```ini
[mlflow]
default_permission = READ
database_uri = sqlite:////mlflow/auth/basic_auth.db
admin_username = admin
admin_password = password1234
```

### `.env.example`

```
# Postgres (shared Dokploy instance)
POSTGRES_HOST=
POSTGRES_PORT=5432
POSTGRES_DB=mlflow
POSTGRES_USER=
POSTGRES_PASSWORD=

# RustFS / S3
AWS_ACCESS_KEY_ID=
AWS_SECRET_ACCESS_KEY=
AWS_DEFAULT_REGION=us-east-1
S3_BUCKET=mlflowartifacts
MLFLOW_S3_ENDPOINT_URL=http://mlflow-storage:9000

# MLflow server
MLFLOW_HOST=0.0.0.0
MLFLOW_PORT=5000
MLFLOW_SERVER_ALLOWED_HOSTS=mlflow.yourdomain.com
MLFLOW_SERVER_CORS_ALLOWED_ORIGINS=https://mlflow.yourdomain.com
MLFLOW_FLASK_SERVER_SECRET_KEY=
```

---

## Part 4: Deploy in Dokploy

1. Go to your project → **Create Service → Docker Compose**
2. Connect your GitHub repo and select `main` branch
3. Add all env vars from `.env.example` with real values:
   - `POSTGRES_HOST`: the internal hostname from your Dokploy Postgres service (e.g. `andromeda-sharedpostgres-6ufyki`)
   - `AWS_ACCESS_KEY_ID`: make up a username (e.g. `mlflow`)
   - `AWS_SECRET_ACCESS_KEY`: make up a strong password
   - `MLFLOW_FLASK_SERVER_SECRET_KEY`: any long random string
4. Click **Deploy**

---

## Part 5: Add the Traefik Route (Manual Workaround)

> **Note**: This is required due to a known Dokploy bug where Docker Compose services don't automatically get Traefik config files. Track the issue at [github.com/Dokploy/dokploy/issues/1574](https://github.com/Dokploy/dokploy/issues/1574).

SSH into your server via Tailscale and create the config file:

```bash
cat > /etc/dokploy/traefik/dynamic/mlflow.yml << 'EOF'
http:
  routers:
    mlflow-router:
      rule: Host(`mlflow.yourdomain.com`)
      service: mlflow-service
      middlewares:
        - redirect-to-https
      entryPoints:
        - web
    mlflow-router-secure:
      rule: Host(`mlflow.yourdomain.com`)
      service: mlflow-service
      entryPoints:
        - websecure
      tls:
        certResolver: letsencrypt
  services:
    mlflow-service:
      loadBalancer:
        servers:
          - url: http://mlflow-server:5000
        passHostHeader: true
EOF
```

Traefik picks this up automatically — no reload needed.

---

## Part 6: Change the Default Admin Password

The default credentials are `admin` / `password1234`. Change the password immediately:

```bash
curl -X PATCH https://mlflow.yourdomain.com/api/2.0/mlflow/users/update-password \
  -u admin:password1234 \
  -H "Content-Type: application/json" \
  -d '{"username": "admin", "password": "your-new-strong-password"}'
```

---

## Part 7: Test the Setup

Install the MLflow client:
```bash
pip install mlflow
```

Run this test script:
```python
import os
import mlflow

os.environ["MLFLOW_TRACKING_USERNAME"] = "admin"
os.environ["MLFLOW_TRACKING_PASSWORD"] = "your-new-strong-password"

mlflow.set_tracking_uri("https://mlflow.yourdomain.com")
mlflow.set_experiment("test-experiment")

with mlflow.start_run():
    mlflow.log_param("learning_rate", 0.01)
    mlflow.log_param("epochs", 10)
    mlflow.log_metric("accuracy", 0.95)
    mlflow.log_metric("loss", 0.05)
    print("Run logged successfully!")
    print(f"Run ID: {mlflow.active_run().info.run_id}")
```

Open `https://mlflow.yourdomain.com` and verify the experiment appears.

---

## Reference: Key Gotchas

| Issue | Fix |
|-------|-----|
| `InvalidBucketName` on bucket creation | Don't use hyphens in `S3_BUCKET` (use `mlflowartifacts` not `mlflow-artifacts`) |
| `could not translate host name` for Postgres | Add `dokploy-network` to the mlflow service networks |
| `Invalid Host header` error | Set `MLFLOW_SERVER_ALLOWED_HOSTS=mlflow.yourdomain.com` |
| CORS blocked requests | Set `MLFLOW_SERVER_CORS_ALLOWED_ORIGINS=https://mlflow.yourdomain.com` |
| `RUSTFS_SERVER_DOMAINS` wrong | Must match the container name: `mlflow-storage:9000` |
| No Traefik config generated | Manually create `/etc/dokploy/traefik/dynamic/mlflow.yml` |
| Auth password resets on redeploy | Mount a volume for `/mlflow/auth` and use `basic_auth.ini` |
| `mlflow[auth]` not in full image | Add `pip install mlflow[auth]` to the command |