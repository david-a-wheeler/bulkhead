/**
 * pi-next-steps: when pi finishes its work, it acts on NEXT-STEPS.md in
 * its working directory, so you can queue instructions by editing a file
 * instead of interrupting it. Once pi has settled (nothing queued, not
 * stopped with Escape), this reads the file, moves it into .next-steps/
 * (named by the time, e.g., 2026-11-05T18-40-12.345Z.md), and sends its
 * text as your next message. So .next-steps/ keeps every version sent,
 * and if pi crashes, the newest one there is what it was working on.
 *
 * Guards against a loop:
 * - The file is moved once it's read, so it isn't read twice.
 * - pi's write and edit tools can't change NEXT-STEPS.md (it's yours).
 * - If you save your old text again (e.g., from an editor buffer that
 *   still has it), only what you added is sent, and nothing if you
 *   added nothing.
 * - After MAX_RUNS runs from the file without you typing anything, it
 *   stops and leaves the file for you.
 */
import { access, mkdir, readFile, rename } from "node:fs/promises";
import { homedir } from "node:os";
import { join, resolve } from "node:path";

const FILE = "NEXT-STEPS.md";
const ARCHIVE = ".next-steps";
const MAX_RUNS = 10;

// Returns an unused name in the archive for a version read now. Names
// sort by time; one clashing with an earlier name gets "_1", "_2", etc.
async function archiveName(cwd) {
	const stamp = new Date().toISOString().replaceAll(":", "-");
	for (let n = 0; ; n++) {
		const name = join(ARCHIVE, stamp + (n ? `_${n}` : "") + ".md");
		try {
			await access(resolve(cwd, name));
		} catch (e) {
			if (e.code === "ENOENT") return name;
			throw e;
		}
	}
}

/** @param {import("@earendil-works/pi-coding-agent").ExtensionAPI} pi */
export default function (pi) {
	let lastSent = "";
	let runs = 0;

	function tell(ctx, message, type = "info") {
		if (ctx.hasUI) ctx.ui.notify(message, type);
	}

	// Your typing resets the count; the messages this sends don't.
	pi.on("input", async (event) => {
		if (event.source !== "extension") runs = 0;
	});

	pi.on("tool_call", async (event, ctx) => {
		if (event.toolName !== "write" && event.toolName !== "edit") return;
		// pi drops a leading "@" and expands "~/" in tool paths.
		const path = event.input.path.replace(/^@/, "").replace(/^~(?=\/|$)/, homedir());
		if (resolve(ctx.cwd, path) === resolve(ctx.cwd, FILE)) {
			return { block: true, reason: `${FILE} is for the user's instructions; don't change it.` };
		}
	});

	pi.on("agent_settled", async (event, ctx) => {
		if (event.aborted || ctx.hasPendingMessages()) return;
		// Say so each time, as a reminder that this extension is here.
		tell(ctx, `Checking for ${FILE}`);
		let text;
		try {
			text = (await readFile(resolve(ctx.cwd, FILE), "utf8")).trim();
		} catch (e) {
			if (e.code === "ENOENT") return;
			throw e;
		}
		if (!text) return;
		if (runs >= MAX_RUNS) {
			tell(ctx, `${FILE}: not read, after ${MAX_RUNS} runs from it in a row; type something to resume.`, "warning");
			return;
		}
		await mkdir(resolve(ctx.cwd, ARCHIVE), { recursive: true });
		const archived = await archiveName(ctx.cwd);
		await rename(resolve(ctx.cwd, FILE), resolve(ctx.cwd, archived));
		const sent = text;
		if (lastSent && text.startsWith(lastSent)) text = text.slice(lastSent.length).trim();
		lastSent = sent;
		if (!text) {
			tell(ctx, `${FILE}: nothing new since last time, so it's moved to ${archived} and not sent.`, "warning");
			return;
		}
		runs++;
		tell(ctx, `Moving ${FILE} to ${archived} and acting on its instructions`);
		pi.sendUserMessage(text);
	});
}
