FROM debian:12-slim

# Basis-Tools
RUN apt-get update && apt-get install -y \
    bash \
    coreutils \
    pigz \
    gzip \
    cifs-utils \
    curl \
    util-linux \
    zip \
    unzip \
    python3 \
    ca-certificates \
    procps \
    && rm -rf /var/lib/apt/lists/*

# Install latest docker CLI compatible with Docker API 1.44+
RUN curl -fsSL https://download.docker.com/linux/static/stable/$(uname -m)/docker-26.1.4.tgz \
    -o /tmp/docker.tgz \
  && tar -xzf /tmp/docker.tgz -C /tmp \
  && mv /tmp/docker/* /usr/bin/ \
  && rm -rf /tmp/docker /tmp/docker.tgz   

WORKDIR /app

# Deine Scripts
COPY backup_sd.sh /app/backup_sd.sh
COPY server.py /app/server.py
COPY docker-boot-start.sh /app/docker-boot-start.sh

RUN chmod +x /app/*.sh /app/server.py

# Optional: wenn du docker-cli im Container brauchst (um Host-Container via /var/run/docker.sock zu steuern),
# kannst du zusätzlich installieren:
# RUN apt-get update && apt-get install -y docker.io && rm -rf /var/lib/apt/lists/*

# API Port
ENV API_PORT=8080

# Standard-Konfig (kannst du bei docker run / compose überschreiben)
ENV BACKUP_DIR=/mnt/syno-backup \
    CIFS_SHARE=//192.168.178.25/System_Backup \
    CIFS_USER=backup \
    CIFS_DOMAIN=WORKGROUP \
    CIFS_PASS=changeme \
    IMAGE_PREFIX=raspi-4gb- \
    RETENTION_COUNT=2 \
    START_DELAY=15 \
    GOTIFY_URL=http://192.168.178.25:6742 \
    GOTIFY_TOKEN=changeme \
    GOTIFY_ENABLED=true

# Optionaler Mount für Marker/First-Boot/Dependencies
VOLUME ["/markers"]

EXPOSE 8080

CMD ["python3", "/app/server.py"]
