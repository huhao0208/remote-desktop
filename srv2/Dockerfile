FROM python:3.11-slim

WORKDIR /app
RUN pip install --no-cache-dir fastapi==0.115.* uvicorn==0.32.*

COPY server.py entrypoint.sh ./
RUN chmod +x entrypoint.sh && mkdir -p /app/data

ENV UU_DATA_DIR=/app/data PYTHONUNBUFFERED=1
EXPOSE 8443
ENTRYPOINT ["/app/entrypoint.sh"]