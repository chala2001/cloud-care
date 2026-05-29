# app/backend/Dockerfile
FROM python:3.12-slim

# Don't write .pyc files; flush logs immediately (so they show in CloudWatch).
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1

WORKDIR /code

# Install deps first (this layer is cached unless requirements.txt changes).
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Then copy the app code.
COPY app ./app

EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]