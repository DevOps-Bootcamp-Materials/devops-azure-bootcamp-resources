#!/usr/bin/env python3
"""
Minimal MCP server — exposes two kubectl tools to Claude Code.

Install: pip install mcp
Configure in ~/.claude/settings.json:
  {
    "mcpServers": {
      "kubectl": {
        "command": "python",
        "args": ["/absolute/path/to/minimal-mcp-server.py"]
      }
    }
  }

Requires: kubectl installed and configured (kubeconfig in default location).
"""

import asyncio
import subprocess
from mcp.server import Server
from mcp.server.stdio import stdio_server
from mcp.types import Tool, TextContent

app = Server("kubectl-tools")


@app.list_tools()
async def list_tools() -> list[Tool]:
    return [
        Tool(
            name="get_pod_status",
            description=(
                "Run 'kubectl get pods' in a namespace and return the output. "
                "Use this to check whether pods are Running, Pending, "
                "CrashLoopBackOff, or in any other state."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "namespace": {
                        "type": "string",
                        "description": "Kubernetes namespace. Defaults to 'default'.",
                    }
                },
            },
        ),
        Tool(
            name="get_recent_events",
            description=(
                "Run 'kubectl get events --sort-by=.lastTimestamp' in a namespace "
                "and return the last 20 lines. Use this to investigate pod failures, "
                "unexpected restarts, or scheduling issues."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "namespace": {
                        "type": "string",
                        "description": "Kubernetes namespace. Defaults to 'default'.",
                    }
                },
            },
        ),
    ]


@app.call_tool()
async def call_tool(name: str, arguments: dict) -> list[TextContent]:
    ns = arguments.get("namespace", "default")

    if name == "get_pod_status":
        cmd = ["kubectl", "get", "pods", "-n", ns, "--output=wide"]
    elif name == "get_recent_events":
        cmd = ["kubectl", "get", "events", "-n", ns, "--sort-by=.lastTimestamp"]
    else:
        return [TextContent(type="text", text=f"Unknown tool: {name}")]

    result = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
    output = result.stdout if result.returncode == 0 else result.stderr

    if name == "get_recent_events":
        output = "\n".join(output.splitlines()[-20:])

    return [TextContent(type="text", text=output or "(no output)")]


async def main():
    async with stdio_server() as (read_stream, write_stream):
        await app.run(read_stream, write_stream, app.create_initialization_options())


if __name__ == "__main__":
    asyncio.run(main())
