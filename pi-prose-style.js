/**
 * pi-prose-style: makes pi check the text it writes with check-prose-style,
 * as Claude Code's PreToolUse hook does. Each write or edit call is turned
 * into Claude Code's hook input and run through the checker, so it's the
 * same rules, including not flagging what an edit keeps. A violation blocks
 * the call, and the model sees why; a heuristic warning (a possible
 * disguised em dash) doesn't block, but it's added to the tool's result.
 * Commit messages are checked by the commit-msg git hook instead.
 */
import { execFile } from "node:child_process";

// From PATH (vm-setup.sh installs it in /usr/local/bin), so tests can
// supply their own.
const CHECKER = "check-prose-style";

// Runs the checker on Claude Code's hook input for one Write or Edit.
// Resolves to { deny: reason }, { warn: message }, or {}.
function check(toolName, toolInput) {
	return new Promise((resolve, reject) => {
		const child = execFile(CHECKER, [], { maxBuffer: 1 << 20 }, (err, stdout) => {
			if (err) return reject(err);
			if (!stdout.trim()) return resolve({});
			try {
				const out = JSON.parse(stdout).hookSpecificOutput ?? {};
				resolve(out.permissionDecision === "deny" ? { deny: out.permissionDecisionReason } : { warn: out.additionalContext });
			} catch (e) {
				reject(e);
			}
		});
		child.stdin?.end(JSON.stringify({ tool_name: toolName, tool_input: toolInput }));
	});
}

/** @param {import("@earendil-works/pi-coding-agent").ExtensionAPI} pi */
export default function (pi) {
	// Warnings by tool call, to add to that call's result.
	const warnings = new Map();

	// A failure here blocks the call (pi fails closed), e.g., if the
	// checker is missing.
	pi.on("tool_call", async (event) => {
		let decisions;
		if (event.toolName === "write") {
			decisions = [await check("Write", { content: event.input.content })];
		} else if (event.toolName === "edit") {
			decisions = await Promise.all(
				event.input.edits.map((e) => check("Edit", { old_string: e.oldText, new_string: e.newText })),
			);
		} else {
			return;
		}
		const denied = decisions.flatMap((d) => (d.deny ? [d.deny] : []));
		if (denied.length > 0) return { block: true, reason: denied.join(" ") };
		const warned = decisions.flatMap((d) => (d.warn ? [d.warn] : []));
		if (warned.length > 0) warnings.set(event.toolCallId, warned.join(" "));
	});

	pi.on("tool_result", async (event) => {
		const warning = warnings.get(event.toolCallId);
		if (warning === undefined) return;
		warnings.delete(event.toolCallId);
		return {
			content: [...event.content, { type: "text", text: warning }],
			structuredContent: event.structuredContent,
		};
	});
}
