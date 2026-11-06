// Tests pi-next-steps.js with a stand-in for pi's extension API.
// Usage: node tests/test_pi_next_steps.mjs DIR (an empty scratch directory)
import assert from "node:assert/strict";
import { existsSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import extension from "../pi-next-steps.js";

const dir = resolve(process.argv[2]);
const file = join(dir, "NEXT-STEPS.md");
const archive = join(dir, ".next-steps");
// The archived versions, oldest first.
const archived = () => readdirSync(archive).sort().map((f) => readFileSync(join(archive, f), "utf8"));

const handlers = {};
const sent = [];
const notes = [];
extension({
	on: (name, handler) => { handlers[name] = handler; },
	sendUserMessage: (text) => sent.push(text),
});
let pending = false;
const ctx = {
	cwd: dir, hasUI: true,
	ui: { notify: (message) => notes.push(message) },
	hasPendingMessages: () => pending,
};
const settle = (aborted = false) => handlers.agent_settled({ type: "agent_settled", aborted }, ctx);
const type = (source = "interactive") => handlers.input({ type: "input", text: "x", source });

// No file, or a blank one: nothing happens.
await settle();
writeFileSync(file, "\n\n");
await settle();
assert.deepEqual(sent, []);

// The file's text is sent, and the file is moved into the archive.
writeFileSync(file, "Run the tests.\n");
await settle();
assert.deepEqual(sent, ["Run the tests."]);
assert.ok(!existsSync(file));
assert.deepEqual(archived(), ["Run the tests.\n"]);
assert.match(notes.at(-2), /^Checking for NEXT-STEPS.md/);
assert.match(notes.at(-1), /^Moving NEXT-STEPS.md to .next-steps\//);

// Not read when you stopped pi or have messages queued.
writeFileSync(file, "Fix the bug.\n");
await settle(true);
pending = true;
await settle();
pending = false;
assert.equal(sent.length, 1);
assert.ok(existsSync(file));

// Old text saved again: only what's new is sent, or nothing.
writeFileSync(file, "Run the tests.\n\nFix the bug.\n");
await settle();
assert.equal(sent.at(-1), "Fix the bug.");
writeFileSync(file, "Run the tests.\n\nFix the bug.\n");
await settle();
assert.equal(sent.length, 2);
assert.ok(!existsSync(file));
// Every version read is kept, under its own name.
assert.equal(archived().length, 3);
assert.equal(archived()[2], "Run the tests.\n\nFix the bug.\n");

// pi's write and edit tools can't change the file; others can be changed.
const call = (toolName, path) => handlers.tool_call({ type: "tool_call", toolName, toolCallId: "1", input: { path } }, ctx);
assert.equal((await call("write", "NEXT-STEPS.md"))?.block, true);
assert.equal((await call("edit", join(dir, "NEXT-STEPS.md")))?.block, true);
assert.equal((await call("write", "@NEXT-STEPS.md"))?.block, true);
assert.equal(await call("write", "notes.md"), undefined);
assert.equal(await call("read", "NEXT-STEPS.md"), undefined);

// It stops after 10 runs in a row from the file, until you type.
type();
for (let i = 0; i < 12; i++) {
	writeFileSync(file, `Step ${i}.\n`);
	await settle();
	type("extension");
}
assert.equal(sent.length, 12);
assert.ok(existsSync(file));
assert.match(notes.at(-1), /type something/);
type();
await settle();
assert.equal(sent.at(-1), "Step 11.");

console.log("pi-next-steps tests passed");
