# EXAMPLE-001: Add Health Check Endpoint

## Description
Add a health check endpoint that returns the service status and version information.
This is needed for Kubernetes liveness/readiness probes and monitoring.

## Requirements
- GET /health endpoint returning JSON
- Response includes: status, version, uptime
- Returns 200 if healthy, 503 if degraded
- Check database connectivity
- Check Redis connectivity (graceful degradation: Redis down = still healthy)

## API

### GET /health
Response (200):
```json
{
  "status": "ok",
  "version": "1.2.3",
  "uptime_seconds": 3600,
  "checks": {
    "database": "ok",
    "redis": "ok"
  }
}
```

Response (503):
```json
{
  "status": "degraded",
  "version": "1.2.3",
  "checks": {
    "database": "fail",
    "redis": "ok"
  }
}
```

## Acceptance Criteria
- [ ] GET /health returns 200 with correct JSON structure
- [ ] Database connectivity is verified
- [ ] Redis failure doesn't cause 503 (graceful degradation)
- [ ] Version is read from build info or config
- [ ] Response time < 500ms

## Implementation Notes
- Follow existing handler patterns in the project
- Use dependency injection for DB/Redis clients
- Add unit tests for health check logic

## Pipeline Command
```bash
./run.sh task tasks/_example
```
