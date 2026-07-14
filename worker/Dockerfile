# Same as app/Dockerfile in the repo - only worker.py is the fixed version
FROM python:3.9-slim

RUN apt-get update && apt-get install -y \
    ffmpeg \
    libsndfile1 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN pip install --no-cache-dir boto3 spleeter

COPY worker.py .

ENV PYTHONUNBUFFERED=1
CMD ["python", "worker.py"]
