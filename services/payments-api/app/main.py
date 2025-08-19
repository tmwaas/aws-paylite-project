from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import os, random, time

from opentelemetry import trace
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter

SERVICE_NAME = os.getenv("SERVICE_NAME", "payments-api")
OTEL_EXPORTER_OTLP_ENDPOINT = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://otel-collector:4318")

resource = Resource.create({"service.name": SERVICE_NAME})
provider = TracerProvider(resource=resource)
processor = BatchSpanProcessor(OTLPSpanExporter(endpoint=f"{OTEL_EXPORTER_OTLP_ENDPOINT}/v1/traces"))
provider.add_span_processor(processor)
trace.set_tracer_provider(provider)
tracer = trace.get_tracer(__name__)

from prometheus_fastapi_instrumentator import Instrumentator

app = FastAPI(title="Payments API")

class PayRequest(BaseModel):
    amount: float
    currency: str = "USD"
    user_id: str

@app.get("/health")
def health():
    return {"status": "ok", "service": SERVICE_NAME}

@app.post("/pay")
def pay(req: PayRequest):
    # Simulate calling risk-scorer
    with tracer.start_as_current_span("call-risk-scorer"):
        time.sleep(0.05)
        risk = random.random()

    if risk > 0.8:
        raise HTTPException(status_code=402, detail="High risk: payment declined")

    tx_id = f"tx_{random.randint(100000, 999999)}"
    return {"transaction_id": tx_id, "risk": round(risk, 3), "amount": req.amount, "currency": req.currency}


# Expose /metrics for Prometheus
Instrumentator().instrument(app).expose(app)
