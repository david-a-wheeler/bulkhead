// Tests pi-prose-style.js with a stand-in for pi's extension API. Needs
// check-prose-style on PATH (ci.sh links it).
import assert from "node:assert/strict";
import extension from "../pi-prose-style.js";

// Banned phrases, split so this file passes the checker itself.
const BAD1 = "dive" + " into";
const BAD2 = "lever" + "age";

const handlers = {};
extension({ on: (name, handler) => { handlers[name] = handler; } });

async function call(toolName, input, toolCallId = "1") {
	return handlers.tool_call({ type: "tool_call", toolName, toolCallId, input });
}

// A violation blocks a write, with the checker's reason.
const blocked = await call("write", { path: "a.md", content: `Let's ${BAD1} it.\n` });
assert.equal(blocked?.block, true);
assert.match(blocked.reason, new RegExp(BAD1));

// Clean text passes.
assert.equal(await call("write", { path: "a.md", content: "This works.\n" }), undefined);

// Any edit with a violation blocks the call; keeping old text doesn't.
assert.equal((await call("edit", { path: "a.md", edits: [
	{ oldText: "a", newText: "b" },
	{ oldText: "c", newText: `We ${BAD2} this.` },
] }))?.block, true);
assert.equal(await call("edit", { path: "a.md", edits: [
	{ oldText: `We ${BAD2} this.`, newText: `We ${BAD2} this. More text.` },
] }), undefined);

// Other tools aren't checked.
assert.equal(await call("bash", { command: `echo '${BAD1}'` }), undefined);

// A heuristic warning doesn't block, but it's added to the result.
assert.equal(await call("write", { path: "a.md", content: "It works - mostly.\n" }, "2"), undefined);
const result = await handlers.tool_result({
	type: "tool_result", toolCallId: "2", input: {}, isError: false,
	content: [{ type: "text", text: "Wrote a.md" }],
});
assert.equal(result.content.length, 2);
assert.match(result.content[1].text, /em dash/);
assert.equal(await handlers.tool_result({ type: "tool_result", toolCallId: "2", content: [] }), undefined);

console.log("pi-prose-style tests passed");
