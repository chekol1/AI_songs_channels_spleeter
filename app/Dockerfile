# Step 1: Use a lightweight Python base
FROM python:3.14-slim

# Step 2: Install system dependencies (FFmpeg is mandatory for audio)
RUN apt-get update && apt-get install -y \
    ffmpeg \
    libsndfile1 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Step 3: Set the working directory
WORKDIR /app

# Step 4: Install Python dependencies
# We install spleeter and boto3 directly
RUN pip install --no-cache-dir boto3 spleeter

# Step 5: Copy your worker script into the container
COPY worker.py .

# Step 6: Set the environment variables (AWS will override these later)
ENV PYTHONUNBUFFERED=1

# Step 7: Run the worker
CMD ["python", "worker.py"]
