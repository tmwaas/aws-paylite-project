FROM python:3.11-slim
WORKDIR /app
COPY app/ /app
RUN pip install --no-cache-dir fastapi uvicorn[standard] opentelemetry-sdk opentelemetry-exporter-otlp opentelemetry-instrumentation-fastapi prometheus-fastapi-instrumentator
EXPOSE 8080
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
