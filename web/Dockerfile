FROM python:3.13-slim
WORKDIR /app
COPY LICENSE /app/LICENSE
COPY gateway.py /app/gateway.py
COPY static /app/static
USER 1000:1000
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 WEB_LISTEN=0.0.0.0
EXPOSE 8090
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 CMD python -c "import os,urllib.request; r=urllib.request.Request('http://127.0.0.1:8090'+os.environ.get('WEB_BASE_PATH','/')+'healthz',headers={'Host':__import__('urllib.parse',fromlist=['urlsplit']).urlsplit(os.environ['WEB_ORIGIN']).netloc}); urllib.request.urlopen(r,timeout=3).read()"
CMD ["python", "gateway.py"]
