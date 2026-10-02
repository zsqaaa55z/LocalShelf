FROM python:3.12-slim
WORKDIR /app
COPY LICENSE /app/LICENSE
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt
COPY server.py readiness.py manual.py thumbnails.py cover_warmup.py authors.py series.py relaxed.py related_cache.py /app/
COPY THIRD_PARTY_NOTICES.md /app/THIRD_PARTY_NOTICES.md
RUN chmod 0644 /app/server.py /app/readiness.py /app/manual.py /app/thumbnails.py /app/cover_warmup.py /app/authors.py /app/series.py /app/relaxed.py /app/related_cache.py /app/requirements.txt /app/THIRD_PARTY_NOTICES.md
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
HEALTHCHECK --interval=60s --timeout=5s --start-period=30s --retries=3 CMD python -c "import json,urllib.request; r=json.load(urllib.request.urlopen('http://127.0.0.1:8089/v2/ready',timeout=3)); assert r.get('ready') is True"
EXPOSE 8089
CMD ["python", "/app/server.py"]
