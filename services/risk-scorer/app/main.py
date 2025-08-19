from fastapi import FastAPI
import os, random, time

from opentelemetry import trace
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter

SERVICE_NAME = os.getenv("SERVICE_NAME", "risk-scorer")
OTEL_EXPORTER_OTLP_ENDPOINT = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://otel-collector:4318")

resource = Resource.create({"service.name": SERVICE_NAME})
provider = TracerProvider(resource=resource)
processor = BatchSpanProcessor(OTLPSpanExporter(endpoint=f"{OTEL_EXPORTER_OTLP_ENDPOINT}/v1/traces"))
provider.add_span_processor(processor)
trace.set_tracer_provider(provider)

from prometheus_fastapi_instrumentator import Instrumentator

app = FastAPI(title="Risk Scorer")

@app.get("/health")
def health():
    return {"status": "ok", "service": SERVICE_NAME}

@app.get("/score")
def score():
    # Simulate variable latency
    time.sleep(random.choice([0.01, 0.02, 0.05, 0.1]))
    return {"score": random.random()}


# Expose /metrics for Prometheus
Instrumentator().instrument(app).expose(app)
