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

SSH into your droplet and set up Temporal:

```bash
# SSH into your server (as forge or root)
ssh forge@your-server-ip

# Clone the repository (as regular user first)
cd ~
git clone https://github.com/joscraw/TemporalProduction.git temporal-setup

# Move to /opt with proper permissions
sudo mv temporal-setup /opt/temporal

# Run the setup script (creates temporal user and fixes ALL permissions)
cd /opt/temporal
sudo bash scripts/setup-droplet.sh
```

**What the script does:**
- Creates `temporal` user
- Installs Docker and Docker Compose
- Sets up firewall (ports 22, 80, 443, 7233)
- Installs Certbot for SSL
- **Automatically fixes all permissions** (sets /opt/temporal to temporal:temporal)
- Configures system optimizations

### 3. Configure Database

Create a database in DigitalOcean:
1. Go to your PostgreSQL cluster in DigitalOcean
2. Click "Users & Databases" tab
3. Create a new database named `temporal`
4. Add your droplet to "Trusted Sources" in the Settings tab

### 4. Configure Environment

```bash
# Switch to temporal user FIRST (they own the directory)
sudo su - temporal
cd /opt/temporal

# Now edit as temporal user (no sudo needed)
nano .env.production
```

Update these values:
```bash
POSTGRES_HOST=your-actual-host.db.ondigitalocean.com
POSTGRES_USER=doadmin
POSTGRES_PASSWORD=your-actual-password
POSTGRES_DB=temporal
DB_PORT=25060

# Use server IP if no domain configured yet
DOMAIN=your.server.ip.address
# OR use your domain if you have one
DOMAIN=temporal.yourdomain.com

# Generate encryption key
TEMPORAL_ENCRYPTION_KEY=<result of: openssl rand -hex 32>
```

Generate the encryption key:
```bash
openssl rand -hex 32
# Copy the output and paste it for TEMPORAL_ENCRYPTION_KEY
```

### 5. Deploy Temporal

```bash
# Already as temporal user from previous step
# Just run deployment
./scripts/deploy.sh
```

**Note:** The temporal user owns /opt/temporal, so no sudo is needed for git pulls or docker commands.

### 6. Verify Deployment

```bash
# Check all containers are running
docker compose --env-file .env.production ps

# Test the UI is accessible
curl -I http://localhost:8080
```

Access your Temporal instance:
- **Web UI**: http://your-server-ip
- **gRPC endpoint**: your-server-ip:7233

### 7. Set Up SSL Certificate (Optional)

**Prerequisites:**
- Domain name pointing to your server IP
- Port 80 accessible (temporarily stop nginx: `docker compose --env-file .env.production stop nginx`)

```bash
# Get SSL certificate (as root or with sudo)
sudo certbot certonly --standalone -d temporal.yourdomain.com --email your-email@example.com

# Create SSL directory
sudo mkdir -p /opt/temporal/nginx/ssl

# Link certificates
sudo ln -s /etc/letsencrypt/live/temporal.yourdomain.com/fullchain.pem /opt/temporal/nginx/ssl/
sudo ln -s /etc/letsencrypt/live/temporal.yourdomain.com/privkey.pem /opt/temporal/nginx/ssl/
sudo ln -s /etc/letsencrypt/live/temporal.yourdomain.com/chain.pem /opt/temporal/nginx/ssl/

# Switch to HTTPS nginx config
cd /opt/temporal
sudo sed -i 's/temporal-http.conf/temporal.conf/g' docker-compose.yml

# Restart nginx with SSL
sudo su - temporal
cd /opt/temporal
docker compose --env-file .env.production restart nginx

# Test auto-renewal
sudo certbot renew --dry-run
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

1. **Git Permission Issues**
   ```bash
   # If you get "detected dubious ownership"
   git config --global --add safe.directory /opt/temporal
   # OR
   sudo git config --global --add safe.directory /opt/temporal

   # If you get "Permission denied" on git pull
   sudo chown -R $USER:$USER /opt/temporal
   ```

2. **Database Connection Failed**
   - Check `.env.production` credentials
   - Verify DigitalOcean database firewall rules (add droplet to Trusted Sources)
   - Ensure database name is `temporal`
   - Test with: `psql -h your-db-host -U doadmin -d temporal`

3. **Out of Memory**
   - Check Docker resource limits
   - Monitor with: `docker stats`
   - Consider upgrading droplet

4. **SSL Certificate Issues**
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