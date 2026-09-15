// Use the official SDK installed in an isolated test directory, never an Agent config.
import { readFileSync } from "node:fs";
import { randomUUID } from "node:crypto";
import assert from "node:assert/strict";
import { pathToFileURL } from "node:url";
const sdk = process.argv[3];
const { Client } = await import(pathToFileURL(`${sdk}/dist/esm/client/index.js`));
const { StreamableHTTPClientTransport } = await import(pathToFileURL(`${sdk}/dist/esm/client/streamableHttp.js`));
const config = JSON.parse(readFileSync(process.argv[2], "utf8"));
for (let pass = 0; pass < 2; pass++) {
  const transport = new StreamableHTTPClientTransport(new URL(config.endpoint), { requestInit: { headers: { Authorization: `Bearer ${config.token}` } } });
  const client = new Client({ name: "foldpin-typescript-check", version: "1" });
  await client.connect(transport);
  const first = await client.listTools();
  assert.equal(first.tools.length, 30);
  let page = first;
  while (page.nextCursor) { page = await client.listTools({ cursor: page.nextCursor }); assert.ok(page.tools.length); }
  if (pass === 0) {
    const call = async (name, args = {}) => {
      const result = await client.callTool({ name: `foldpin_${name}`, arguments: { libraryId: config.libraryId, ...args } });
      assert.ok(!result.isError, name);
      return result.structuredContent;
    };
    const args = { text: "TypeScript SDK test", idempotencyKey: randomUUID() };
    const note = await call("create_note", args);
    assert.equal((await call("create_note", args)).noteId, note.noteId);
    const changed = await call("update_note", { noteId: note.noteId, expectedRevision: note.revision, text: "Updated from TypeScript", idempotencyKey: randomUUID() });
    assert.equal((await call("read_note", { noteId: note.noteId })).blocks[0].text, "Updated from TypeScript");
    const pending = await call("quit", { idempotencyKey: randomUUID() });
    assert.equal(pending.status, "awaiting_user");
    assert.equal((await call("cancel_operation", { operationId: pending.operationId })).status, "cancelled");
  }
  await transport.terminateSession();
  await client.close();
}
console.log("TypeScript MCP SDK", JSON.parse(readFileSync(`${sdk}/package.json`, "utf8")).version, "compatible");
