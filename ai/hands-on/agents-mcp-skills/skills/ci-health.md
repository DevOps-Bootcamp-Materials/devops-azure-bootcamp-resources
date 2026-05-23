# CI Health Check

When invoked, perform the following steps using the GitHub MCP tools:

1. Identify the GitHub repository. Use the `origin` remote of the current
   working directory, or accept a `<owner>/<repo>` argument if the user
   provides one.
2. Fetch the last 10 workflow runs for the repository's default branch.
3. For each failed run, retrieve the failing job's name and the first
   meaningful error line from its log output.
4. Produce a structured report:
   - Total runs inspected: N (X passing, Y failing).
   - For each failure: workflow name, failing job, first error line, commit SHA.
5. Conclude with a single sentence verdict: CI is healthy, unstable, or broken.