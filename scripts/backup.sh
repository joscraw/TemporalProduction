#!/bin/bash

# Temporal Backup Script
# Backs up Elasticsearch data and configuration

set -e

BACKUP_DIR="/opt/temporal/backups"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_NAME="temporal-backup-$TIMESTAMP"

# DigitalOcean Spaces configuration (optional)
DO_SPACES_KEY="${DO_SPACES_KEY}"
DO_SPACES_SECRET="${DO_SPACES_SECRET}"
DO_SPACES_BUCKET="${DO_SPACES_BUCKET}"
DO_SPACES_REGION="${DO_SPACES_REGION:-nyc3}"

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

log "Starting Temporal backup..."

# Create backup directory
mkdir -p "$BACKUP_DIR/$BACKUP_NAME"

# Backup Elasticsearch data
log "Backing up Elasticsearch data..."
docker run --rm \
    --network temporal-network \
    -v "$BACKUP_DIR/$BACKUP_NAME:/backup" \
    elasticsearch:7.17.27 \
    bash -c "curl -X PUT 'http://temporal-elasticsearch:9200/_snapshot/backup' -H 'Content-Type: application/json' -d '{
        \"type\": \"fs\",
        \"settings\": {
            \"location\": \"/backup/elasticsearch\"
        }
    }' && \
    curl -X PUT 'http://temporal-elasticsearch:9200/_snapshot/backup/snapshot_$TIMESTAMP?wait_for_completion=true'" || \
    warning "Elasticsearch snapshot failed, trying alternative method..."

# Alternative: Export Elasticsearch data as JSON
if [ $? -ne 0 ]; then
    log "Using alternative Elasticsearch backup method..."
    docker exec temporal-elasticsearch \
        elasticdump \
        --input=http://localhost:9200 \
        --output=/backup/elasticsearch-data.json \
        --type=data || true
fi

# Backup configuration files
log "Backing up configuration files..."
cp -r /opt/temporal/*.yml "$BACKUP_DIR/$BACKUP_NAME/" 2>/dev/null || true
cp -r /opt/temporal/.env* "$BACKUP_DIR/$BACKUP_NAME/" 2>/dev/null || true
cp -r /opt/temporal/dynamicconfig "$BACKUP_DIR/$BACKUP_NAME/" 2>/dev/null || true
cp -r /opt/temporal/nginx "$BACKUP_DIR/$BACKUP_NAME/" 2>/dev/null || true

# Backup Docker volumes
log "Backing up Docker volumes..."
docker run --rm \
    -v temporal_temporal-data:/data \
    -v "$BACKUP_DIR/$BACKUP_NAME:/backup" \
    alpine \
    tar czf /backup/temporal-data.tar.gz -C /data .

docker run --rm \
    -v temporal_elasticsearch-data:/data \
    -v "$BACKUP_DIR/$BACKUP_NAME:/backup" \
    alpine \
    tar czf /backup/elasticsearch-data.tar.gz -C /data .

# Create backup manifest
cat > "$BACKUP_DIR/$BACKUP_NAME/manifest.json" << EOF
{
    "timestamp": "$TIMESTAMP",
    "date": "$(date)",
    "temporal_version": "$(docker inspect temporalio/server:latest --format='{{.RepoDigests}}')",
    "backup_type": "full",
    "components": [
        "elasticsearch",
        "configuration",
        "volumes"
    ]
}
EOF

# Compress backup
log "Compressing backup..."
cd "$BACKUP_DIR"
tar czf "$BACKUP_NAME.tar.gz" "$BACKUP_NAME/"
rm -rf "$BACKUP_NAME"

# Upload to DigitalOcean Spaces (if configured)
if [ -n "$DO_SPACES_KEY" ] && [ -n "$DO_SPACES_SECRET" ] && [ -n "$DO_SPACES_BUCKET" ]; then
    log "Uploading backup to DigitalOcean Spaces..."

    # Install s3cmd if not present
    if ! command -v s3cmd &> /dev/null; then
        apt-get update && apt-get install -y s3cmd
    fi

    # Configure s3cmd
    cat > ~/.s3cfg << EOF
[default]
access_key = $DO_SPACES_KEY
secret_key = $DO_SPACES_SECRET
host_base = $DO_SPACES_REGION.digitaloceanspaces.com
host_bucket = %(bucket)s.$DO_SPACES_REGION.digitaloceanspaces.com
use_https = True
EOF

    # Upload backup
    s3cmd put "$BACKUP_DIR/$BACKUP_NAME.tar.gz" \
        "s3://$DO_SPACES_BUCKET/temporal-backups/$BACKUP_NAME.tar.gz" \
        --acl-private || warning "Failed to upload to Spaces"
fi

# Clean up old backups
log "Cleaning up old backups..."
find "$BACKUP_DIR" -name "temporal-backup-*.tar.gz" -mtime +$BACKUP_RETENTION_DAYS -delete

# Clean up old backups from Spaces
if [ -n "$DO_SPACES_BUCKET" ]; then
    s3cmd ls "s3://$DO_SPACES_BUCKET/temporal-backups/" | \
    while read -r line; do
        FILE_DATE=$(echo "$line" | awk '{print $1}')
        FILE_NAME=$(echo "$line" | awk '{print $4}')
        if [ $(date -d "$FILE_DATE" +%s) -lt $(date -d "$BACKUP_RETENTION_DAYS days ago" +%s) ]; then
            s3cmd del "$FILE_NAME"
        fi
    done
fi

# Report backup size
BACKUP_SIZE=$(du -h "$BACKUP_DIR/$BACKUP_NAME.tar.gz" | cut -f1)

log "==========================================="
log "Backup completed successfully!"
log "Backup name: $BACKUP_NAME.tar.gz"
log "Backup size: $BACKUP_SIZE"
log "Backup location: $BACKUP_DIR/"
if [ -n "$DO_SPACES_BUCKET" ]; then
    log "Remote location: s3://$DO_SPACES_BUCKET/temporal-backups/"
fi
log "==========================================="