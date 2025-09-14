#!/bin/bash

# Temporal Deployment Script
# Run this as the temporal user to deploy/update Temporal

set -e

DEPLOY_DIR="/opt/temporal"
BACKUP_DIR="/opt/temporal/backups"
LOG_FILE="/opt/temporal/logs/deploy-$(date +%Y%m%d-%H%M%S).log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
    exit 1
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$LOG_FILE"
}

# Create necessary directories
mkdir -p "$DEPLOY_DIR/logs"
mkdir -p "$BACKUP_DIR"

log "Starting Temporal deployment..."

# Check if running as temporal user
if [ "$USER" != "temporal" ]; then
    error "This script must be run as the temporal user"
fi

# Change to deployment directory
cd "$DEPLOY_DIR" || error "Failed to change to deployment directory"

# Load environment variables
if [ -f .env.production ]; then
    log "Loading environment variables..."
    set -a
    source .env.production
    set +a
else
    error ".env.production file not found!"
fi

# Validate required environment variables
if [ -z "$POSTGRES_HOST" ] || [ -z "$POSTGRES_PASSWORD" ]; then
    error "Database configuration missing in .env.production"
fi

# Test database connection
log "Testing database connection..."
docker run --rm \
    -e PGPASSWORD="$POSTGRES_PASSWORD" \
    postgres:16 \
    psql -h "$POSTGRES_HOST" -p "$DB_PORT" -U "$POSTGRES_USER" -d defaultdb -c "SELECT 1" > /dev/null 2>&1 || \
    error "Failed to connect to database. Check your credentials."

# Pull latest images
log "Pulling latest Docker images..."
docker compose --env-file .env.production pull

# Backup current deployment if exists
if [ -f docker-compose.yml ]; then
    log "Backing up current configuration..."
    BACKUP_NAME="backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_DIR/$BACKUP_NAME"
    cp -r *.yml .env* dynamicconfig/ "$BACKUP_DIR/$BACKUP_NAME/" 2>/dev/null || true
fi

# Health check function
health_check() {
    local service=$1
    local max_attempts=30
    local attempt=0

    while [ $attempt -lt $max_attempts ]; do
        if docker compose --env-file .env.production ps --services --filter "status=running" | grep -q "^$service$"; then
            if docker compose --env-file .env.production exec -T "$service" temporal health-check 2>/dev/null; then
                return 0
            fi
        fi
        sleep 2
        attempt=$((attempt + 1))
    done
    return 1
}

# Deploy with zero-downtime if already running
if docker compose --env-file .env.production ps --services --filter "status=running" 2>/dev/null | grep -q temporal; then
    log "Performing rolling update..."

    # Start new containers alongside old ones
    docker compose --env-file .env.production up -d --no-deps --scale temporal=2 temporal

    # Wait for new container to be healthy
    sleep 10
    if health_check temporal; then
        log "New Temporal container is healthy"
        # Remove old container
        docker compose --env-file .env.production up -d --no-deps --remove-orphans temporal
    else
        warning "Health check failed, rolling back..."
        docker compose --env-file .env.production down
        docker compose --env-file .env.production up -d
    fi
else
    log "Starting Temporal services..."
    docker compose --env-file .env.production up -d

    # Wait for services to be ready
    log "Waiting for services to be ready..."
    sleep 10

    # Simple health check - just verify container is running
    if docker compose --env-file .env.production ps | grep -q "temporal-server.*Up"; then
        log "Temporal server is running"
    else
        warning "Temporal server may still be starting up"
    fi
fi

# Show service status
log "Service status:"
docker compose --env-file .env.production ps

# Verify Temporal is accessible
log "Verifying Temporal accessibility..."
if curl -f http://localhost:7233 2>/dev/null; then
    log "Temporal gRPC endpoint is accessible"
else
    warning "Could not verify Temporal gRPC endpoint"
fi

if curl -f http://localhost:8080 2>/dev/null; then
    log "Temporal UI is accessible"
else
    warning "Could not verify Temporal UI"
fi

# Clean up old images
log "Cleaning up old Docker images..."
docker image prune -f

# Setup cron job for automated updates (optional)
if [ "$1" == "--setup-cron" ]; then
    log "Setting up automated deployment cron job..."
    (crontab -l 2>/dev/null; echo "0 3 * * 1 cd $DEPLOY_DIR && ./scripts/deploy.sh >> $DEPLOY_DIR/logs/cron-deploy.log 2>&1") | crontab -
    log "Cron job created for weekly updates (Monday 3 AM)"
fi

log "==========================================="
log "Deployment completed successfully!"
log "==========================================="
log ""
log "Access points:"
log "- Temporal UI: https://$DOMAIN (via nginx)"
log "- Temporal gRPC: $DOMAIN:7233"
log "- Admin tools: docker compose exec temporal-admin-tools temporal"
log ""
log "Logs available at: $LOG_FILE"
log "==========================================="