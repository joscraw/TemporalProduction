# Temporal Production Deployment on DigitalOcean

This directory contains production-ready configuration files for deploying Temporal on DigitalOcean.

## Quick Start

### 1. Create DigitalOcean Resources

#### Droplet
- **Size**: 8GB RAM, 4 vCPUs ($48/mo)
- **OS**: Ubuntu 22.04 LTS
- **Region**: Choose closest to your users
- **Options**: Enable monitoring and backups

#### Managed PostgreSQL Database
- Go to DigitalOcean → Databases → Create Database
- Choose PostgreSQL 15+
- Select Basic plan ($15/mo)
- Note the connection details

### 2. Initial Server Setup

SSH into your droplet as root and run:

```bash
# Download and run setup script
wget https://raw.githubusercontent.com/your-repo/temporal-production/main/scripts/setup-droplet.sh
chmod +x setup-droplet.sh
./setup-droplet.sh
```

### 3. Deploy Temporal

```bash
# Switch to temporal user
su - temporal

# Clone this repository
cd /opt/temporal
git clone https://github.com/your-repo/temporal-production.git .

# Configure environment
cp .env.production.example .env.production
nano .env.production  # Add your database credentials

# Make scripts executable
chmod +x scripts/*.sh

# Deploy
./scripts/deploy.sh
```

### 4. Set Up SSL Certificate

```bash
# As root user
certbot certonly --standalone -d temporal.yourdomain.com

# Link certificates
ln -s /etc/letsencrypt/live/temporal.yourdomain.com/fullchain.pem /opt/temporal/nginx/ssl/
ln -s /etc/letsencrypt/live/temporal.yourdomain.com/privkey.pem /opt/temporal/nginx/ssl/
ln -s /etc/letsencrypt/live/temporal.yourdomain.com/chain.pem /opt/temporal/nginx/ssl/

# Auto-renewal
certbot renew --dry-run
```

## Configuration Files

### `.env.production`
Main configuration file. **MUST** be configured with:
- DigitalOcean Managed Database credentials
- Your domain name
- Optional: DigitalOcean Spaces for backups

### `docker-compose.yml`
Production Docker Compose configuration with:
- Resource limits
- Health checks
- Restart policies
- Proper networking

### `dynamicconfig/production.yaml`
Temporal server configuration for production workloads.

### `nginx/temporal.conf`
Nginx reverse proxy with:
- SSL termination
- Rate limiting
- Security headers
- gRPC proxy for workers

## Scripts

### `setup-droplet.sh`
Initial server setup:
- Installs Docker
- Configures firewall
- Sets up monitoring
- Creates temporal user

### `deploy.sh`
Deployment script:
- Zero-downtime updates
- Health checks
- Automatic rollback on failure

### `backup.sh`
Backup script:
- Backs up Elasticsearch data
- Saves configurations
- Optional: Upload to DigitalOcean Spaces

## Security Considerations

1. **Database Security**
   - Use DigitalOcean's managed database
   - Configure connection pooling
   - Enable SSL for database connections

2. **Network Security**
   - Only expose ports 443 (HTTPS) and 7233 (gRPC)
   - Use DigitalOcean's firewall
   - Configure nginx rate limiting

3. **SSL/TLS**
   - Use Let's Encrypt for certificates
   - Enable auto-renewal
   - Strong cipher suites only

4. **Access Control**
   - SSH key-only authentication
   - Non-root user for deployment
   - Fail2ban for brute force protection

## Monitoring

### Basic Monitoring
- DigitalOcean droplet monitoring (built-in)
- Docker logs: `docker compose logs -f`
- Temporal metrics: http://localhost:7234/metrics

### Advanced Monitoring (Optional)
- Prometheus + Grafana (configs in deployment/)
- Temporal metrics dashboard
- Alert configuration

## Backup Strategy

### Automated Backups
```bash
# Set up daily backups at 2 AM
crontab -e
0 2 * * * /opt/temporal/scripts/backup.sh
```

### Manual Backup
```bash
./scripts/backup.sh
```

### Restore from Backup
```bash
# Extract backup
tar xzf backups/temporal-backup-TIMESTAMP.tar.gz

# Restore Docker volumes
docker compose down
docker volume rm temporal_temporal-data temporal_elasticsearch-data
docker compose up -d
```

## Troubleshooting

### Check Service Status
```bash
docker compose ps
docker compose logs temporal
```

### Health Check
```bash
curl http://localhost:7233  # gRPC endpoint
curl http://localhost:8080  # UI endpoint
```

### Common Issues

1. **Database Connection Failed**
   - Check `.env.production` credentials
   - Verify DigitalOcean database firewall rules
   - Test with: `psql -h your-db-host -U doadmin -d defaultdb`

2. **Out of Memory**
   - Check Docker resource limits
   - Monitor with: `docker stats`
   - Consider upgrading droplet

3. **SSL Certificate Issues**
   - Verify domain DNS points to droplet
   - Check certificate: `certbot certificates`
   - Renew manually: `certbot renew`

## Maintenance

### Update Temporal
```bash
# Pull latest images and redeploy
docker compose pull
./scripts/deploy.sh
```

### Clean Up
```bash
# Remove old images
docker image prune -a

# Clean old logs
find /opt/temporal/logs -name "*.log" -mtime +30 -delete
```

## Support

For issues specific to:
- **Temporal**: https://community.temporal.io/
- **DigitalOcean**: https://www.digitalocean.com/support/
- **This deployment**: Create an issue in your repository