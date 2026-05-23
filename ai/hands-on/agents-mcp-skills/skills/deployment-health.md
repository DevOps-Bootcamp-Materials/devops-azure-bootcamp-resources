# Deployment Health Check

Requires: a Kubernetes MCP server with kubectl access, or kubectl available as
a local tool via Bash.

When invoked, perform the following steps:

1. Accept a namespace argument from the user, or default to `default`.
2. List all Deployments in the namespace. For each one, record:
   - Name
   - Desired vs. ready replica counts
   - Whether any pods are in CrashLoopBackOff, OOMKilled, or Pending state
3. For any Deployment with at least one unhealthy pod:
   - Describe the pod to check recent events and restart count
   - Retrieve the last 50 lines of the failing container's logs
4. Produce a structured health report:
   - Healthy deployments: list names
   - Unhealthy deployments: for each, the pod name, failure reason, restart
     count, and the first error line from logs
5. Conclude with a triage recommendation:
   - If restarts are high and the error is OOMKilled: suggest increasing memory limits
   - If the pod is Pending: check node resource pressure (kubectl describe node)
   - If CrashLoopBackOff with an application error: surface the log excerpt for
     the engineer to investigate