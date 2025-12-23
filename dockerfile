FROM python:3.11-slim

WORKDIR /app

# Optional: ein paar Tools nachinstallieren (z.B. mosquitto-clients)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        mosquitto-clients \
    && rm -rf /var/lib/apt/lists/*

# server.py ins Image
COPY server.py /app/server.py
RUN chmod +x /app/server.py

EXPOSE 8080

CMD ["python", "/app/server.py"]
