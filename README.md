# pi_network_imager
# docker buildx create --use --name multi
# docker buildx inspect --bootstrap

docker buildx build \
  --platform linux/arm64 \
  -t urmelausmall/pinetworkimager:4.0 \
  --push \
  .

############################################

sudo mkdir -p /backupos_shared
sudo nano /etc/fstab

  LABEL=BACKUP_SHARED  /backupos_shared  ext4  defaults,nofail  0  2

sudo mount -a
ls /backupos_shared

############################################

sudo nano /usr/local/sbin/pi-backup-reboot-watcher.sh

############################################

# /etc/systemd/system/pi-backup-reboot-watcher.service

[Unit]
Description=Pi Backup Reboot Watcher
After=local-fs.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/pi-backup-reboot-watcher.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target



sudo chmod +x /usr/local/sbin/pi-backup-reboot-watcher.sh
sudo systemctl daemon-reload
sudo systemctl enable --now pi-backup-reboot-watcher.service
