#!/bin/bash

# Temporal Production Setup Script for DigitalOcean Droplet
# Run this script as root on a fresh Ubuntu 22.04 droplet

set -e

echo "==========================================="
echo "Temporal Production Setup for DigitalOcean"
echo "==========================================="

# Update system
echo "Updating system packages..."
apt update && apt upgrade -y

# Install essential packages
echo "Installing essential packages..."
apt install -y \
    curl \
    wget \
    git \
    vim \
    htop \
    ufw \
    fail2ban \
    software-properties-common \
    apt-transport-https \
    ca-certificates \
    gnupg \
    lsb-release

# Install Docker
echo "Installing Docker..."
if ! command -v docker &> /dev/null; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt update
    apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
fi

# Create temporal user
echo "Creating temporal user..."
if ! id -u temporal > /dev/null 2>&1; then
    useradd -m -s /bin/bash temporal
    usermod -aG docker temporal
    usermod -aG sudo temporal
fi

# Setup firewall
echo "Configuring firewall..."
ufw --force enable
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp    # SSH
ufw allow 80/tcp    # HTTP
ufw allow 443/tcp   # HTTPS
ufw allow 7233/tcp  # Temporal gRPC
ufw reload

# Configure fail2ban for SSH protection
echo "Configuring fail2ban..."
cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true
port = 22
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
EOF

systemctl restart fail2ban

# Setup Docker daemon configuration
echo "Configuring Docker daemon..."
cat > /etc/docker/daemon.json << EOF
{
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "100m",
        "max-file": "3"
    },
    "storage-driver": "overlay2"
}
EOF

systemctl restart docker

# Create application directory
echo "Creating application directory..."
mkdir -p /opt/temporal
chown -R temporal:temporal /opt/temporal

# Install Certbot for SSL certificates
echo "Installing Certbot..."
snap install core
snap refresh core
snap install --classic certbot
ln -sf /snap/bin/certbot /usr/bin/certbot

# Setup swap (recommended for smaller droplets)
echo "Setting up swap space..."
if [ ! -f /swapfile ]; then
    fallocate -l 4G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab
fi

# Optimize system settings
echo "Optimizing system settings..."
cat >> /etc/sysctl.conf << EOF

# Temporal optimizations
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 60
net.ipv4.tcp_keepalive_probes = 3
net.core.somaxconn = 1024
net.ipv4.tcp_max_syn_backlog = 2048
vm.swappiness = 10
EOF

sysctl -p

# Install monitoring tools
echo "Installing monitoring tools..."
wget -q -O - https://packages.grafana.com/gpg.key | apt-key add -
add-apt-repository "deb https://packages.grafana.com/oss/deb stable main"
apt update
apt install -y prometheus node-exporter

# Setup log rotation
echo "Configuring log rotation..."
cat > /etc/logrotate.d/temporal << EOF
/opt/temporal/logs/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    create 0644 temporal temporal
    sharedscripts
    postrotate
        docker exec temporal-server kill -USR1 1
    endscript
}
EOF

# Create deployment script location
echo "Setting up deployment scripts..."
mkdir -p /opt/temporal/scripts
chown -R temporal:temporal /opt/temporal/scripts

echo "==========================================="
echo "Initial setup complete!"
echo "==========================================="
echo ""
echo "Next steps:"
echo "1. Copy your temporal-production files to /opt/temporal/"
echo "2. Configure your .env.production file with database credentials"
echo "3. Set up SSL certificate: certbot certonly --nginx -d your-domain.com"
echo "4. Run the deployment script as temporal user"
echo ""
echo "To switch to temporal user: su - temporal"
echo "To deploy: cd /opt/temporal && ./scripts/deploy.sh"
echo ""
echo "Security reminders:"
echo "- Set up SSH key authentication and disable password auth"
echo "- Configure DigitalOcean managed database firewall rules"
echo "- Enable automated backups in DigitalOcean"
echo "==========================================="