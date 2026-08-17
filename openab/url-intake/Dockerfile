FROM python:3.12-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends ffmpeg \
 && rm -rf /var/lib/apt/lists/* \
 && pip install --no-cache-dir \
      py-cord requests youtube-transcript-api yt-dlp pypdf opencc-python-reimplemented

WORKDIR /app
COPY bot.py /app/bot.py
COPY test_bot.py /app/test_bot.py
RUN python -m unittest -v /app/test_bot.py

CMD ["python", "-u", "/app/bot.py"]
