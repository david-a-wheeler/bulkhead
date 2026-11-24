# goose: what it checks, and how it fits here

[goose](https://github.com/aaif-goose/goose) is an AI agent harness
that Block started; the Linux Foundation's Agentic AI Foundation (AAIF)
has looked after it since 2026-04 (docs: <https://goose-docs.ai>). These
are my notes from its docs and source as of v1.60.2 (2026-11-24), on
whether its own security mechanisms conflict with ours or add to them.

## In short

goose adds a few checks of its own, but none is a security boundary,
and ours are stronger. goose has no OS-level sandbox: its tools (e.g.,
its `shell` tool) run with your user's permissions, and its checks
decide only whether goose *asks* before running something. Most of them
rely on a model's judgment, are off by default, or fail open. Here,
goose runs inside a compartment under nono, like every other harness,
and that's what limits what it can do. Its own checks don't conflict
with ours, so you can turn them on as an extra layer, but don't count
on them.

## goose's own mechanisms

| Mechanism | What it does | Default | Compared to ours |
|---|---|---|---|
| Permission modes (`GOOSE_MODE`: `auto`, `approve`, `smart_approve`) | Asks before tools it classifies as "write" tools. | `auto` (asks nothing) | The docs say the read/write classification is "interpreted by your LLM provider", so a confused or manipulated model can misclassify. A shell command the agent runs can do anything its sandbox allows, whatever the mode. |
| Per-tool permissions | Always allow, ask, or never allow, per tool. | None | Advisory, like the modes. Stored in `~/.config/goose`, which an agent could edit if it were writable (it isn't here). |
| Prompt-injection check (`SECURITY_PROMPT_ENABLED`) | Pattern matching on tool calls, optionally an ML classifier at an endpoint you supply. | Off | A heuristic; new attacks get past it. |
| "Adversary" reviewer (`~/.config/goose/adversary.md`) | A second model call reviews each `shell` tool call against your rules, and blocks it if the reviewer says so. | Off unless the file exists | I read the source (`adversary_inspector.rs`): if the review fails, or there's no provider, it allows the call. It reviews only `shell` unless you list more tools. It costs a model call per tool call. |
| "Egress inspector" | Finds destinations (URLs, git remotes, `scp` targets, ...) in tool calls. | On | I read the source (`egress_inspector.rs`): it only logs. Every result is hard-coded to allow. nono's proxy is what actually limits where an agent can go. |
| Extension allowlist (`GOOSE_ALLOWLIST`) | Refuses to install an MCP extension whose command isn't on a list fetched from a URL. | Off | Useful for an organization; here, an extension runs inside the compartment anyway. |
| Keyring | Keeps API keys in the system keyring over D-Bus, else in a plain-text `~/.config/goose/secrets.yaml`. | Keyring | A compartment has no session bus, and `compart goose` passes the engine's key in the environment, so it sets `GOOSE_DISABLE_KEYRING` and nothing goes in `secrets.yaml`. |
| Telemetry | Anonymous usage data. | Off | `compart goose` turns it off explicitly too. |

## Where goose would undo our protections, and what we do about it

goose's nono pack (`nolabs-ai/goose`) grants `~/.config/goose`
read-write. That directory holds goose's `config.yaml`, including its
*extensions*: commands goose runs each time it starts. So if it were
shared and writable, an agent in one compartment could add an extension
there that runs in every other compartment, turn off approvals or the
adversary reviewer for all of them, or read any key in `secrets.yaml`.
So:

- `compartment-paths` makes `~/.config/goose` read-only. goose works
  with that: it takes its whole provider setup from the environment, and
  writes nothing there in a normal session. A change it would save
  there (e.g., "always allow" for a tool, or `/mode`) fails; set those
  from outside a compartment.
- goose's sessions (`~/.local/share/goose`) and logs
  (`~/.local/state/goose`) are private to each compartment. The pack's
  other writable grants were already covered: all of `~/.cache` is
  private, `~/.agents` is read-only, and each compartment has its own
  `/tmp` (goose uses `/tmp/goose-UID`).
- goose's `goose update` would replace its own binary; `vm-setup.sh`
  installs goose root-owned in `/usr/local/bin`, so no agent can.

## Other things worth knowing

- goose reads `AGENTS.md` (and `.goosehints`) in the project and in
  `~/.config/goose`, so `vm-setup.sh` links `~/.config/goose/AGENTS.md`
  to the shared `~/.agents/AGENTS.md`, as it does for pi.
- At startup goose fetches a model catalog from `models.dev` (a GET,
  which tells that site you're running goose). It has a bundled copy,
  so it works without it, e.g., under `~/sensitive`.
- goose's tools inherit its environment, so a command the agent runs
  can read the engine's API key. That's the same as with pi; the key
  only reaches the engine, through a tunnel you control.
- The documented installer (`curl ... download_cli.sh | bash`) doesn't
  check a checksum or signature, runs `goose configure` (that is,
  goose itself, unsandboxed), and may add lines to your shell's startup
  files. So `vm-setup.sh` doesn't use it. goose's release files carry a
  signed SLSA build provenance attestation from its `release.yml`
  workflow, so `vm-setup.sh` checks that with `gh attestation verify`,
  as well as the SHA-256 GitHub publishes and the cooling period
  (`INFER_COOLING_DAYS`) we use for the engine's releases.

## Sources

- [Permission modes](https://github.com/aaif-goose/goose/blob/main/documentation/docs/guides/managing-tools/goose-permissions.md)
- [Environment variables](https://goose-docs.ai/docs/guides/environment-variables/)
- [Extension allowlist](https://goose-docs.ai/docs/guides/allowlist/)
- [Hints files](https://goose-docs.ai/docs/guides/context-engineering/using-goosehints)
- [Installation](https://goose-docs.ai/docs/getting-started/installation) and [`download_cli.sh`](https://github.com/aaif-goose/goose/blob/main/download_cli.sh)
- Source: [`egress_inspector.rs`](https://github.com/aaif-goose/goose/blob/main/crates/goose/src/security/egress_inspector.rs), [`adversary_inspector.rs`](https://github.com/aaif-goose/goose/blob/main/crates/goose/src/security/adversary_inspector.rs)
