# Canary (dev-free via NGINX)
- Default: v1 weight=9, v2 weight=1 (~10% canary).
- Increase to 25/75, 50/50, then 100/0 if SLOs are healthy.
- Roll back by restoring weights and `nginx -s reload`.
- Record P95 latency and 5xx rate from Grafana during the steps.
