# Base image from ECR Public, not Docker Hub: Docker Hub limits anonymous pulls
# ("toomanyrequests"), and shared CI runners hit that limit often.
FROM public.ecr.aws/docker/library/python:3.12-slim

# Logs go straight to stdout -> CloudWatch, no buffering; no .pyc files in the image.
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

# Copy requirements first: this layer is cached until requirements.txt changes,
# so a code-only change rebuilds in seconds.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY src/ .

# Do not run as root inside the container.
RUN useradd --create-home --uid 10001 appuser
USER appuser

EXPOSE 8000
# Default command = the API. The worker service overrides it with: python worker.py
CMD ["uvicorn", "api:app", "--host", "0.0.0.0", "--port", "8000"]
