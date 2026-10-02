FROM python:3.12-slim
RUN apt-get update && apt-get install -y --no-install-recommends openssl && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY LICENSE /app/LICENSE
COPY server.py /app/server.py
COPY audit.py /app/audit.py
ENV PYTHONUNBUFFERED=1
EXPOSE 8443
CMD ["python", "/app/server.py"]
