#!/bin/bash
# DataPilot Installation Script (GHCR Version)
# This script will install and run DataPilot on your system.

set -e

echo "================================================="
echo "   🚀 Welcome to the DataPilot Installer 🚀"
echo "================================================="

# 1. Check for Docker
if ! command -v docker &> /dev/null; then
    echo "❌ Error: Docker is not installed on this system."
    echo "Please install Docker and Docker Engine before running this script."
    echo "See: https://docs.docker.com/engine/install/"
    exit 1
fi

if ! docker compose version &> /dev/null; then
    echo "❌ Error: Docker Compose is not installed on this system."
    echo "Please install Docker Compose plugin."
    exit 1
fi

# 2. Generating Application Files
echo "⚙️  Generating configuration files..."

cat << 'EOF' > docker-compose.yml
version: '3.8'

services:
  db:
    image: pgvector/pgvector:pg15
    restart: always
    environment:
      POSTGRES_USER: ${POSTGRES_USER:-data_pilot_user}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:-secure_password_123}
      POSTGRES_DB: ${POSTGRES_DB:-data_pilot}
    ports:
      - "${DB_PORT:-5432}:5432"
    volumes:
      - data_pilot_postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: [ "CMD", "pg_isready", "-U", "${POSTGRES_USER:-data_pilot_user}" ]
      interval: 10s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7-alpine
    restart: always
    ports:
      - "${REDIS_PORT:-6379}:6379"
    volumes:
      - data_pilot_redis_data:/data
    command: redis-server --appendonly yes --maxmemory 256mb --maxmemory-policy allkeys-lru
    healthcheck:
      test: [ "CMD", "redis-cli", "ping" ]
      interval: 10s
      timeout: 3s
      retries: 5

  backend:
    image: ${GHCR_BACKEND_IMAGE:-ghcr.io/datapilot-co/datapilot-backend:1.0.4}
    restart: always
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_healthy
    environment:
      - DATABASE_URL=postgresql://${POSTGRES_USER:-data_pilot_user}:${POSTGRES_PASSWORD:-secure_password_123}@db:5432/${POSTGRES_DB:-data_pilot}
      - REDIS_URL=redis://redis:6379/0
      - SECRET_KEY=${SECRET_KEY}
      - ENCRYPTION_KEY=${ENCRYPTION_KEY}
      - CORS_ORIGINS=http://localhost:${FRONTEND_PORT:-80},http://${HOST_IP:-localhost}:${FRONTEND_PORT:-80}
      - PORT=8008
    ports:
      - "${BACKEND_PORT:-8008}:8008"

  frontend:
    image: ${GHCR_FRONTEND_IMAGE:-ghcr.io/datapilot-co/datapilot-frontend:1.0.4}
    restart: always
    environment:
      - VITE_API_URL=http://${HOST_IP:-localhost}:${BACKEND_PORT:-8008}/api/v1
    ports:
      - "${FRONTEND_PORT:-80}:80"
    depends_on:
      - backend

volumes:
  data_pilot_postgres_data:
  data_pilot_redis_data:
EOF

if [ ! -f .env ]; then
    echo "Creating new .env file..."
    
    # Optional interactive env setup
    read -p "Enter the Host IP or Domain name where this will be accessed [default: localhost]: " host_ip
    host_ip=${host_ip:-localhost}
    
    read -p "Enter a new secure Database Password [default: secure_pass_123]: " db_pass
    db_pass=${db_pass:-secure_pass_123}
    
    # Generate a random 32 char secret key if openssl is available
    if command -v openssl &> /dev/null; then
        secret_key=$(openssl rand -hex 32)
        encryption_key=$(openssl rand -hex 32)
    else
        secret_key="secret_key_$(date +%s)_random"
        encryption_key="enc_key_$(date +%s)_random"
    fi

cat << EOF > .env
# DataPilot Production Environment Variables
FRONTEND_PORT=80
BACKEND_PORT=8008
DB_PORT=5432
REDIS_PORT=6379

HOST_IP=${host_ip}
POSTGRES_USER=data_pilot_user
POSTGRES_PASSWORD=${db_pass}
POSTGRES_DB=data_pilot
SECRET_KEY=${secret_key}
ENCRYPTION_KEY=${encryption_key}

GHCR_FRONTEND_IMAGE=ghcr.io/datapilot-co/datapilot-frontend:1.0.4
GHCR_BACKEND_IMAGE=ghcr.io/datapilot-co/datapilot-backend:1.0.4
EOF
    
    echo "✅ Environment variables configured in .env file."
else
    echo "ℹ️  Existing .env file found. Skipping generation."
fi

# 3. Authenticate with GHCR
echo ""
echo "🔐 GitHub Container Registry Authentication"
echo "To download DataPilot, you need a Personal Access Token (PAT) from the vendor."
echo "If you don't have one, ask your vendor for a 'read:packages' token."
echo "Username should be your GitHub username or the vendor's GitHub organization account if specified by them."
read -p "GitHub Username (e.g. your-github-name): " gh_user
read -s -p "GitHub Personal Access Token (PAT): " gh_token
echo ""

if [ -z "$gh_user" ] || [ -z "$gh_token" ]; then
    echo "❌ Error: Username and Token are required to download DataPilot."
    exit 1
fi

echo "Logging in to ghcr.io..."
# Note: In some sudo environments (like macOS Docker Desktop), docker.sock might return 500 errors.
# Using 'sudo -u $SUDO_USER' or relying on standard docker group permissions is usually safer.
echo "$gh_token" | docker login ghcr.io -u "$gh_user" --password-stdin

if [ $? -ne 0 ]; then
    echo "❌ Error: Failed to authenticate with GHCR. Please check your token."
    exit 1
fi

# 4. Run Docker Compose
echo "🚀 Pulling images and starting DataPilot containers..."
docker compose pull
docker compose up -d

echo ""
echo "⏳ Waiting for the backend service to initialize and become healthy..."
# Backend konteynerının ayağa kalkması ve healthy olması için 60 saniyeye kadar bekliyoruz.
max_retries=30
count=0
while [ $count -lt $max_retries ]; do
    status=$(docker compose ps backend --format "{{.Status}}" | grep -o 'healthy')
    if [ "$status" == "healthy" ]; then
        break
    fi
    echo -n "."
    sleep 2
    count=$((count+1))
done
echo ""

if [ "$status" != "healthy" ]; then
    echo "⚠️ Warning: Backend service took too long to become healthy. Database seeding might not have completed."
else
    echo "⚙️  Seeding database with default admin and demo data..."
    # Backend sağlıklı olduktan sonra migration'ları (seeding dahil) zorunlu olarak senkronize ediyoruz.
    docker compose exec -T backend alembic upgrade head || echo "⚠️ Warning: Database seeding failed."
    echo "✅ Database initialized successfully!"
fi

echo ""
echo "================================================="
echo "✅ DataPilot has been successfully installed and started!"
echo ""
echo "🌐 You can access the application at:"
# Attempt to read FRONTEND_PORT from .env, default to 80
front_port=$(grep "^FRONTEND_PORT=" .env | cut -d '=' -f 2 || echo "80")
host_addr=$(grep "^HOST_IP=" .env | cut -d '=' -f 2 || echo "localhost")

echo "   http://${host_addr}:${front_port}"
echo ""
echo "🔑 Default Admin Credentials:"
echo "   Email:    admin@datapilot.co"
echo "   Password: admin123"
echo ""
echo "📦  Demo Data (Domains, Glossary Terms) is pre-loaded!"
echo ""
echo "⚠️  IMPORTANT: Please change the default password"
echo "   immediately after your first login!"
echo "================================================="
