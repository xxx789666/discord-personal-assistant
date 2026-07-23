# pdf-publisher — vault 行程變動 → Steel 轉 PDF → 發 Discord（見 publish.py）。
# Build 由 docker-compose.yml 的 pdf-publisher 服務驅動。
FROM python:3.12-slim
RUN pip install --no-cache-dir markdown requests
COPY publish.py /app/publish.py
CMD ["python", "-u", "/app/publish.py"]
