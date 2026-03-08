# EXAMPLE-002: Health Check — Database Connectivity

## Description
Implement the database connectivity check as part of the health check endpoint.

## Requirements
- Ping the database with a timeout of 2 seconds
- Return "ok" if ping succeeds, "fail" otherwise
- Use existing database connection from DI container
- Do NOT create a new connection for health checks

## Interface
```
type HealthChecker interface {
    CheckDatabase(ctx context.Context) error
}
```

## Acceptance Criteria
- [ ] Database ping with 2s timeout
- [ ] Proper error wrapping
- [ ] Unit test with mock database
