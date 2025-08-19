FROM python:3.11-slim
WORKDIR /app
COPY app/ /app
RUN pip install --no-cache-dir fastapi uvicorn[standard] opentelemetry-sdk opentelemetry-exporter-otlp opentelemetry-instrumentation-fastapi prometheus-fastapi-instrumentator
EXPOSE 8081
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8081"]
