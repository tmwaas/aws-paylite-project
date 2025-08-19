# Blue/Green Rollback (prod-demo concept)
- For ECS + ALB + CodeDeploy, rollback is automatic if the new task set fails `/health`.
- Manual: `aws deploy stop-deployment --deployment-id d-XXXXXXXX --auto-rollback-enabled`
