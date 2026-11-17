"""
Starts the server over stdio the way Claude Desktop does, lists its tools and calls a read-only one.

    uv run python smoke_test.py                       # get_my_schedule for today
    uv run python smoke_test.py get_customer_summary '{"customer": "Sam Patel"}'
"""

import asyncio
import json
import sys

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


async def main(tool: str, arguments: dict):
    server = StdioServerParameters(command=sys.executable, args=["-m", "verdant_assistant.server"])
    async with stdio_client(server) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            tools = (await session.list_tools()).tools
            print(f"{len(tools)} tools: {', '.join(t.name for t in tools)}\n")
            result = await session.call_tool(tool, arguments)
            for block in result.content:
                print(getattr(block, "text", block))
            return 1 if result.is_error else 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main(sys.argv[1] if len(sys.argv) > 1 else "get_my_schedule",
                     json.loads(sys.argv[2]) if len(sys.argv) > 2 else {})))
