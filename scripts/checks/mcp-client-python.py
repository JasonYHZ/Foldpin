"""Official Python SDK compatibility check against a synthetic local test library."""
import asyncio
import json
import sys
import uuid
import importlib.metadata
import httpx2
from mcp import ClientSession, types
from mcp.client.streamable_http import streamable_http_client

async def main():
    config = json.load(open(sys.argv[1]))
    async with httpx2.AsyncClient(headers={"Authorization": "Bearer " + config["token"]}) as http:
        async with streamable_http_client(config["endpoint"], http_client=http) as streams:
            async with ClientSession(*streams) as session:
                initialized = await session.initialize()
                assert initialized.protocol_version == "2025-11-25"
                page = await session.list_tools()
                assert len(page.tools) == 30 and page.next_cursor
                second = await session.list_tools(params=types.PaginatedRequestParams(cursor=page.next_cursor))
                assert second.tools
                while second.next_cursor:
                    second = await session.list_tools(params=types.PaginatedRequestParams(cursor=second.next_cursor))
                async def call(name, **args):
                    result = await session.call_tool("foldpin_" + name, {"libraryId": config["libraryId"], **args})
                    assert not result.is_error, name
                    return result.structured_content
                args = dict(idempotencyKey=str(uuid.uuid4()), text="Python SDK test")
                note = await call("create_note", **args)
                replay = await call("create_note", **args)
                assert note["noteId"] == replay["noteId"]
                changed = await call("update_note", noteId=note["noteId"], expectedRevision=note["revision"], idempotencyKey=str(uuid.uuid4()), text="Updated from Python")
                read = await call("read_note", noteId=note["noteId"])
                assert read["blocks"][0]["text"] == "Updated from Python"
                pending = await call("quit", idempotencyKey=str(uuid.uuid4()))
                assert pending["status"] == "awaiting_user"
                cancelled = await call("cancel_operation", operationId=pending["operationId"])
                assert cancelled["status"] == "cancelled"
        # A new initialize after session termination must remain usable.
        async with streamable_http_client(config["endpoint"], http_client=http) as streams:
            async with ClientSession(*streams) as session:
                await session.initialize()
                assert (await session.list_tools()).tools
    print("Python MCP SDK", importlib.metadata.version("mcp"), "compatible")

asyncio.run(main())
