FROM python:3.11-slim

WORKDIR /app

# Optional: ein paar Tools nachinstallieren (z.B. mosquitto-clients)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        mosquitto-clients \
        systemd-sysv \
    && rm -rf /var/lib/apt/lists/*

# server.py ins Image
COPY server.py /app/server.py
COPY mqtt_discovery.sh /app/mqtt_discovery.sh
RUN chmod +x /app/server.py /app/mqtt_discovery.sh

EXPOSE 8080

CMD ["sh", "-c", "/app/mqtt_discovery.sh && python /app/server.py"]
