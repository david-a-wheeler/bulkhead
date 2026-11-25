# Research related to running local AI securely

These are background research results related to running local AI securely.

Most of this research was done by Claude and at most lightly edited.
Don't treat this dcoument as truth, it's more a source of ideas to consider.

## Sources

### llama.cpp's own security policy

<https://github.com/ggml-org/llama.cpp/security> (ggml-org; the
SECURITY.md text is undated, and the advisories are dated individually)

This is the most authoritative source here, since it's the engine we run.

* It says there's no reliable way to detect a malicious model, so you
  should run untrusted models in an isolated environment (a container
  or VM). It also says a model's trustworthiness isn't binary.
* For untrusted inputs, it recommends sandboxing, prompt-injection
  testing, keeping llama.cpp updated, and sanitizing input.
* For untrusted networks, it says not to expose the RPC backend
  (`rpc-server`) or llama-server at all, to check artifact hashes
  against known-good values, and to encrypt data in transit. (The
  note about RPC and the server was added in April 2025, commit
  ab47dec, PR #13061.)
* For multi-tenant use, it mentions network separation, rate limits,
  and GPU side channels.
* It says none of the topics under "Using llama.cpp securely" count as
  vulnerabilities. They're operator guidance, not reportable bugs.
* **The private disclosure program is disabled.** Reporters are asked
  to submit fixes as public PRs. So a security fix can be public, and
  visible to attackers, before it's in a release.
* Recent advisories it lists include:
  * GHSA-j8rj-fmpv-wcxw (2026-03-26, Critical): unauthenticated remote
    code execution through the RPC backend (a `GRAPH_COMPUTE`
    buffer=0 bypass).
  * GHSA-96jg-mvhq-q7q7 (2026-03-18, High): GGUF tensor parsing
    overflow.
  * GHSA-3p4r-fq3f-q74v (2026-03-12, High): a bypass of the
    CVE-2025-53630 fix (integer overflow in GGUF parsing).
  * GHSA-8947-pfff-2f3c (2026-01-05, Low): llama-server out-of-bounds
    write.
* Older GGUF parser bugs found in searches: CVE-2025-49847
  (GHSA-8wwf-w4qm-gpqr, a buffer overflow in vocabulary loading,
  fixed in b5662), CVE-2025-53630 (integer overflow in GGUF parsing),
  CVE-2024-21825 (heap overflow, possible code execution when you load
  a crafted `.gguf`), and CVE-2026-52131 (a reachable assertion in the
  GGUF reader, i.e., denial of service). See
  <https://osv.dev/vulnerability/CVE-2025-49847> and
  <https://access.redhat.com/security/cve/CVE-2026-52131>.

### DEF CON 34: 10 vulnerabilities in llama.cpp

<https://www.esecurityplanet.com/threats/def-con-34-10-vulnerabilities-put-local-ai-at-risk/>
(Ken Underhill, eSecurity Planet, 2026-08-10; summarizing Cyera's
research)

* Cyera presented 10 llama.cpp bugs (use-after-free, integer overflow,
  out-of-bounds access) in the Android JNI bindings, llama-server's
  HTTP request lifecycle, and GGUF metadata processing. VulnCheck
  assigned CVE-2026-43622 through CVE-2026-43632 (skipping 43625).
* As of a June 2026 assessment of build b9445, five were unpatched,
  including two llama-server use-after-free bugs, CVE-2026-43631 and
  CVE-2026-43632, each CVSS 9.2.
* Mitigations: don't use `--sleep-idle-seconds` on a server that takes
  untrusted traffic; don't bind to 0.0.0.0 without an authenticating
  reverse proxy; move Android JNI users past b7446; validate input
  before `llama_batch_init`; and don't restore state or KV cache from
  untrusted sources.
* I didn't read Cyera's own report, and I don't know which of the
  five are fixed in the builds we run (b11669 and later).

### "Bleeding Llama": a malicious GGUF leaks Ollama's memory

<https://pasqualepillitteri.it/en/news/2343/bleeding-llama-malicious-gguf-local-llm-memory-leak>
(Pasquale Pillitteri, 2026-05-11)

* Describes CVE-2026-7482 in Ollama's Go GGUF code: an out-of-bounds
  heap read when a GGUF declares tensor dimensions bigger than its real
  data. Three unauthenticated API calls (`POST /api/blobs/sha256:HASH`,
  `/api/create`, `/api/push`) can leak process memory, including other
  users' chats, system prompts, and API keys. The article reports it's
  fixed in Ollama 0.17.1.
* It also mentions CVE-2026-33298 (integer overflow in llama.cpp's
  `ggml_nbytes`, fixed in b7824) and an SGLang GGUF remote code
  execution bug (CVE-2026-5760, CVSS 9.8).
* Mitigations: bind to 127.0.0.1 behind an authenticating reverse
  proxy, check where GGUF files come from, sandbox the runtime (e.g.,
  Docker `--read-only`, Firejail, gVisor, `sandbox-exec`), rotate any
  secrets in the engine's environment, and firewall the port.
* The key point for us: a memory-safe language didn't prevent this, and
  "safe" formats like GGUF still need parsers that can have bugs. A
  memory leak exposes whatever the engine process holds.

### Exposed Ollama servers (Cisco Talos, and others)

<https://blogs.cisco.com/security/detecting-exposed-llm-servers-shodan-case-study-on-ollama>
(Giannis Tziakouris and Elio Biasiotto, Cisco Talos, 2025-09-01)

* Using Shodan banners and ports (Ollama on 11434; llama.cpp on 8000
  and 8080; also vLLM, LM Studio, and others), they found 1,139
  exposed Ollama servers; about 214 (18.8%) were serving models with no
  authentication.
* Mitigations: require an API key or OAuth2, put endpoints behind a
  firewall, VPN, or IP-restricted reverse proxy, rate-limit, change
  default ports, suppress identifying banners, check uploaded models by
  hash or signature, and scan yourself for exposure regularly.

Related reports, which I read only through search summaries:

* SentinelLABS with Censys counted 175,108 unique exposed Ollama hosts
  in 130 countries, and described operators who scan for them and add
  them to a pool of stolen compute (Pillar Security's "Operation
  Bizarre Bazaar" is the best-documented case).
  <https://www.sentinelone.com/labs/silent-brothers-ollama-hosts-form-anonymous-ai-network-beyond-platform-guardrails/>
  (it returned HTTP 429 when we tried to read it, so this is
  unverified).
* The Register's coverage of the Cisco study:
  <https://www.theregister.com/2025/09/02/exposed_ollama_servers_insecure_research/>.
* A Cloud Security Alliance research note (May 2026) says 31% of the
  Ollama servers it queried answered unauthenticated prompts. The
  document says it was produced with AI help and hasn't had official
  CSA review.
  <https://labs.cloudsecurityalliance.org/research/csa-research-note-exposed-ai-infrastructure-selfhosted-secur/>

The common cause is configuration: binding to 0.0.0.0, or permissive
cloud firewall rules. Neither Ollama nor llama-server requires
authentication by default.

### How to secure local LLM inference: sandbox plus egress

<https://www.kunalganglani.com/blog/secure-local-llm-inference>
(Kunal Ganglani, 2026-09-20, updated 2026-10-29)

* Two zones: a "download station" with allowlisted access to model
  registries, and an inference enclave with no Internet access at all.
* Egress controls: Docker `--network none`, host firewall rules scoped
  to a dedicated UID (nftables/iptables owner matching), or Kubernetes
  default-deny egress. Plan for DNS explicitly.
* Run as non-root, drop capabilities (no `SYS_ADMIN`, no
  `--privileged`, no host PID or IPC namespaces), and use a read-only
  root filesystem.
* Pin model hashes in git; prefer safetensors over pickle; scan
  downloads (antivirus or YARA).
* Put the agent's tools (shell, git, browser) in their own sandboxes,
  separate from the engine.
* Log denied egress and DNS queries, and keep the logs about 30 days.
* His ranking of isolation layers (container, VM, gVisor) is opinion,
  not measurement.

### Sandboxing local models on macOS

<https://engineered.at/articles/sandboxing-local-models-on-macos>
(Universal Bits, via Engineered.at, 2026-03-12; the page is short, and
this summary rests mostly on its "AI Summary" block)

* Runs llama-server under macOS `sandbox-exec` with a profile that
  blocks outbound network and limits reads and writes, serving an
  OpenAI-compatible API on port 8080.
* A wrapper downloads missing GGUF files with curl *before* the sandbox
  starts, since the sandbox forbids network.
* Mentions QEMU VMs with SLiRP user networking (reaching the host at
  10.0.2.2:8080) as a heavier option.
* This is the closest match to our design that I found, and it's much
  less detailed than ours. A web search on 2026-10-18 (recorded in
  `local-ai-plan.md`) found no published, tested `(deny default)`
  profile for Metal inference, and I didn't find one now either.

### NVIDIA: sandboxing agentic workflows

<https://developer.nvidia.com/blog/practical-security-guidance-for-sandboxing-agentic-workflows-and-managing-execution-risk>
(Rich Harang, NVIDIA AI Red Team, 2026-01-30)

About coding agents, not inference engines, but it's the most concrete
guidance I found for the harness side.

* The main threat is indirect prompt injection: attacker text arriving
  through repos, pull requests, git history, agent config files
  (`.cursorrules`, `CLAUDE.md`), or MCP responses.
* Mandatory controls:
  * default-deny network egress, with allowlists enforced by an HTTP
    proxy or IP/port rules, and **DNS limited to trusted resolvers**,
    to block DNS exfiltration;
  * no file writes outside the workspace;
  * **no writes to agent config files, hooks, or extensions, even
    inside the workspace.**
* Recommended controls:
  * sandbox the whole IDE and every process it spawns;
  * prefer VM or microVM isolation over shared-kernel sandboxes;
  * per-action approval, not "allow once, run many";
  * inject secrets through a broker rather than environment variables;
  * give sandboxes a lifecycle: ephemeral, or rebuilt periodically, so
    anything an attacker planted doesn't persist.

### The lethal trifecta

<https://simonwillison.net/2025/Jun/16/the-lethal-trifecta/>
(Simon Willison, 2025-06-16)

* An agent that has all three of (1) access to private data,
  (2) exposure to untrusted content, and (3) a way to communicate
  externally can be tricked into sending your data out.
* Guardrail products don't fix it: 95% detection is a failing grade in
  application security.
* For users, the only dependable defense is to never combine all three
  in one agent. For developers, he points to CaMeL and the "Design
  Patterns for Securing LLM Agents against Prompt Injections" paper.
* Vendors usually "fix" each reported attack by closing that one
  exfiltration path, which leaves the others.
* This applies to local models exactly as to cloud ones: running the
  model locally doesn't change what the harness can do.

### Weight-level backdoors ("Lazarus")

<https://www.csoonline.com/article/4247354/rewriting-less-than-10-neurons-in-an-llm-can-turn-it-into-a-sleeper-backdoor.html>
(Gyana Swain, CSO Online, 2026-11-11; reporting Microsoft Research and
Microsoft Threat Intelligence)

* Rewriting a handful of rarely used neurons in a model's final
  feed-forward layer, with no retraining, makes it emit attacker
  commands when it sees a trigger. On Nemotron-Terminal-8B, changing 7
  of over 12,000 neurons gave malicious output in at least 98.8% of
  held-out trigger cases, with similar results on **Qwen 3.6-27B** and
  Gemma-4-31B-IT. The changed models pass standard evaluations.
* It needs write access to the checkpoint, i.e., whoever publishes
  the file you download (including a quantizer or fine-tuner).
* Scanners caught 91.4% of altered checkpoints, with a 9.7% false
  positive rate.
* Recommendations: compare weights against the declared base model,
  verify publishers and hashes, keep approved models in a private
  registry rather than letting tools download directly, restrict agent
  permissions, isolate agent-generated code, control egress, and
  require human approval for high-impact actions.
* Microsoft says it hasn't seen attackers use this yet.
* Related: Anthropic's 2024 "Sleeper Agents" paper showed models that
  write secure code normally but insert vulnerabilities on a trigger,
  surviving safety training (<https://arxiv.org/abs/2401.05566>), and
  "Sleeper Cell" studies time-triggered backdoors in tool-using agents
  (<https://arxiv.org/abs/2603.03371>). I didn't read either paper for
  this summary.

## What we already do

Comparing against `local-ai-plan.md`, we already follow most of this
advice:

* The engine listens only on 127.0.0.1, VMs reach it through SSH
  tunnels, it requires an API key, and CORS is restricted.
* No `--tools`, MCP, RPC backend, `/slots`, `--slot-save-path`, or
  `--sleep-idle-seconds`; no restoring KV state from anywhere.
* Downloads happen outside the engine's sandbox (our `manage-models.sh`
  is the "download station"), each checked against the publisher's
  SHA-256, and only GGUF or safetensors, checked by their first bytes.
* The engine runs as its own hidden account under a macOS sandbox with
  no outbound network (including DNS, as of Phase B2) and almost no
  writes, which is what llama.cpp's policy asks for.
* Harnesses run in VMs under nono, with no long-lived credentials;
  secrets come from a broker that needs a human click.
* We noted GPU side channels (LeftoverLocals) in "Keeping data off the
  SSD".

### Lind

The [Lind project](https://lind-project.github.io/) exists to
execute "untrusted POSIX applications as mutually isolated compartments
inside a single unprivileged host process" with "no kernel modifications,
no elevated privileges... while keeping the isolation mechanism pluggable
and the system-call policy layer uniform".

## Some lessons we aren't using (yet)

In rough order of importance.

1. **Protect agent config and hooks from the agent.** nono lets a
   harness write anywhere under the current directory, which includes
   `.git/config`, `.git/hooks/`, `AGENTS.md`, `CLAUDE.md`, and any
   per-project harness settings. I believe that's a real path out of
   the sandbox: a harness could set `core.hooksPath` or add a hook in a
   repo's `.git/config`, and the next time *I* run `git commit` or
   `git push` outside the sandbox, the hook runs as me, with my
   `BULKHEAD_AUTH_SESSION`. NVIDIA calls blocking these writes
   mandatory. I haven't tested whether a repo-local `core.hooksPath`
   overrides our global one (git's normal precedence says it does).
   This applies to every VM, not just the local AI.

   A plain nono profile can't do this on Linux: Land&#108;ock is allow-only,
   so it can't deny a subdirectory of an allowed one, and nono refuses
   to start with an overlapping `deny` rather than ignore it. nono's
   supervised mode (seccomp-notify checks of each open against a deny
   list) is the documented Linux workaround; I haven't tried it. From
   outside the sandbox, `git -c core.hooksPath=...` in the human-side
   wrapper beats repo-local config, but it only covers hooks: other
   repo-local settings (e.g., `core.fsmonitor`, `core.sshCommand`,
   filter drivers) also run commands. So a fuller fix would check a
   sandbox-touched repo's `.git/config` and `.git/hooks` before I run
   git in it, or run my git commands in a sandbox too.

2. **Design the secure VM around the lethal trifecta.** It'll have
   private data by definition, and probably untrusted content (web
   pages, documents). The planned domain allowlist narrows the third
   leg but doesn't remove it: any allowed host that accepts data (a
   code host, a paste site, a search engine's query string) is an
   exfiltration channel. I think the safest design is that a session
   with the sensitive data has *no* external communication, and
   anything needing the Internet happens in a separate session or VM,
   with me moving data between them.

3. **Restrict DNS in the VMs.** `nftables.template.conf` allows DNS
   (port 53) to any server, so data can leave in DNS queries even when
   HTTP is allowlisted. We closed this on the host (Phase B2), not in
   the VMs. For the secure VM, allow DNS only to the one resolver, and
   check whether nono's `--allow-domain` proxy also stops DNS lookups
   by commands the harness runs.

4. **Treat a matching SHA-256 as provenance, not safety.** It proves we
   got the file the publisher posted; Lazarus shows a publisher (or
   anyone who can change their repo) can backdoor weights invisibly,
   and it was demonstrated on a Qwen 27B model. We already prefer
   well-known quantizers; I'd go further: prefer files from the
   original lab or ggml-org, treat fine-tunes and "abliterated" models
   as untrusted (we already found one that broke tool calls), and keep
   reviewing what the model writes and runs as I would a stranger's
   pull request. Weight comparison against a base model isn't
   practical for quantized files today.

5. **Watch llama.cpp's advisories, and don't let the cooling period
   delay security fixes.** llama.cpp has no private disclosure, so
   fixes appear as public PRs before releases, and the DEF CON work
   left critical server bugs unpatched for months. Our 7-day cooling
   period is good against malicious releases, but it also delays fixes.
   We already have the lever (raising `LLAMA_CPP_MIN` installs a newer
   release); what's missing is a habit or a script that checks the
   advisory list and says when to use it. Our exposure is lower than
   most, since only the VMs can reach the engine and only with the key.

6. **Rebuild the secure VM periodically, or use snapshots.** NVIDIA
   recommends ephemeral or periodically rebuilt sandboxes, so anything
   planted (in dotfiles, caches, or project files) doesn't persist. Our
   VMs are long-lived. `vm-setup.sh` is idempotent, which makes
   rebuilding from scratch practical; a UTM snapshot taken after setup
   would make it quick.

7. **Review sandbox denials routinely.** Both Ganglani and NVIDIA
   recommend logging denied egress. We check the macOS sandbox log by
   hand after changes; a periodic check (perhaps in `infer-doctor.sh`)
   would catch a compromised or misbehaving engine probing for a way
   out.

Things considered and don't think we need: changing default ports and
hiding banners (the engine isn't reachable from any network), rate
limiting (single user), antivirus or YARA scans of GGUF files (unlikely
to catch a parser exploit or a weight backdoor), and an mTLS reverse
proxy (SSH tunnels already authenticate and encrypt the path).
