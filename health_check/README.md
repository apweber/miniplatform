README

# Installation instructions
``` bash
# 1. Install and enable cron on AlmaLinux 10
sudo dnf install -y cronie
sudo systemctl enable --now crond

# 2. Copy files into place
sudo mkdir -p /opt/miniplatform/scripts /var/log/miniplatform
sudo cp health_check.sh health_check.conf /opt/miniplatform/scripts/
sudo chmod +x /opt/miniplatform/scripts/health_check.sh

# 3. Install the logrotate config
sudo cp logrotate.conf /etc/logrotate.d/miniplatform-health
sudo logrotate -d /etc/logrotate.d/miniplatform-health   # dry run to verify

# 4. Add the cron job (runs every 5 minutes)
echo "*/5 * * * * root /opt/miniplatform/scripts/health_check.sh --quiet" \
    | sudo tee /etc/cron.d/miniplatform-health

# 5. Test it manually first
/opt/miniplatform/scripts/health_check.sh --report
```

