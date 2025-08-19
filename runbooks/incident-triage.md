# Incident Triage (dev-free)
1. Confirm scope: check NGINX `/health` (port 80).
2. Check services:
   - `sudo docker ps`
   - `curl localhost:8080/health` (payments v1)
   - `curl localhost:18080/health` (payments v2 if running)
   - `curl localhost:8081/health` (risk-scorer)
3. Roll back canary:
   - Edit `/etc/nginx/nginx.conf` weights back to `weight=10` for v2 or comment it out.
   - `sudo nginx -s reload`
4. Review logs:
   - `docker logs <container>`
   - `/var/log/nginx/access.log`, `error.log`
5. Verify recovery: synthetic ping returns to normal.
