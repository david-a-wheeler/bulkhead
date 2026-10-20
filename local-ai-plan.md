# Local AI plan

This is the plan for running local AI models on my Mac for work on
sensitive data. It records the goals, the design we've settled on, what's
already implemented, what we've measured, and the work that remains. See
`architecture.md` for the overall bulkhead design this builds on; once
this is built, the lasting parts belong there.

## Current state (2026-10-19)

Working, for **non-sensitive use only**: there's no secure VM yet (mytux
is a normal VM with full network access), and the sleep watcher has
passed only one forced sleep, so keep running `./infer-access.sh off`
on the Mac before closing the lid until step 8 is done. UTM crashed
during that sleep; if that's common, avoid sleeping the Mac while VMs
run anyway.

* On the Mac, `host-setup.sh` installs llama.cpp and llama-swap under
  `/opt` and runs llama-swap as the `local.infer` launchd daemon, as
  `_infer`, under the sandbox profile in "Host sandbox". Models are in
  `/Users/Shared/models`. The API key is in
  `~/.config/bulkhead/infer-api-key` on the Mac and on mytux. A second
  run said the engine was up to date.
* `./infer-access.sh shared` opened the tunnel from mytux (a launchd
  agent), replacing the hand-started one.
* On mytux, `vm-setup.sh` installed pi, `nopi`, and the `infer-logs`
  user services. `nopi --print 'Say hello in five words.'` answered
  through the tunnel, using `qwen3.8-27b`, and llama-swap's and
  llama-server's logs reached the journal.
* The macOS log showed no sandbox denials for llama-swap or
  llama-server. It did show llama-swap's performance monitor running
  `ioreg` every 5 seconds, denied reading `/etc/passwd`; the config now
  turns that monitor off (`performance: disabled: true`). After a rerun
  of `host-setup.sh` restarted the engine, those denials stopped.
* On 2026-10-19 a forced sleep (`Software Sleep`, lid open; this setup's
  AppleClamshellCausesSleep is No, so a lid close wouldn't sleep) ran
  the sleep hook: infer-watch unloaded the model 4 seconds before the
  sleep, and on wake it reopened the tunnel from mytux. A request after
  wake got HTTP 200 and reloaded llama-server. The sleepimage's
  modification time didn't change (still Aug 20). After a DarkWake the
  Mac went back to sleep citing "Thermal Emergency Sleep", but
  `pmset -g thermlog` recorded no thermal or performance warnings, and
  the log said "Ignored DarkWake thermal emergency signal"; I believe
  it's spurious.
* Still to check from step 3: the tunnel coming back after mytux
  reboots.
* I deleted the trial's files from `/Users/Shared` (including the RAM
  disk prototype's scripts; its daemon was already gone). Only `models`
  and macOS's own items remain there.
* The trial's scripts are in `,infer-test/` in this repo (not
  committed), kept for reference; their results are in "Test results".

## Background and goals

I normally use Claude, but sometimes I work on sensitive information
that must never leave my machine, so it can never be sent to Claude. I
want a local environment for that work. I'll keep using Claude when I
can, so nothing here may interfere with running Claude in my other VMs.

The host is macOS on an M5 Max laptop with 128 GB of RAM, running Linux
guest VMs under UTM. A model run inside a VM would be slower, so models
run natively on macOS, under a completely separate account.

I don't fully trust the models or the inference engine: a model might
be malicious and try to send my sensitive data out. So:

* The engine runs as an account that can't see my files or VMs.
* I reach it only over a simulated local network that machines outside
  the Mac can't reach. (I might make exceptions later for other
  machines I control.)
* Everything the engine processes (prompts, outputs, the KV cache) is
  ephemeral: it stays in RAM, disappears when the Mac turns off, and is
  never written to the SSD. That's for confidentiality, and also so I
  don't wear out the SSD.
* The sensitive data itself lives in a new Linux VM with full disk
  encryption, so it stays secret while that VM isn't running. Harness
  logs and session state stay there too, protected by that encryption;
  "ephemeral" applies only to the inference host.
* I can switch among several models (one loaded at a time) through one
  standard interface.

## Design

### Secure VM

* A new Ubuntu VM with full disk encryption (LUKS) holds the sensitive
  data and runs the harnesses. I'll try both goose and pi.
* It needs Internet access. nono inside the VM limits each harness's
  file and network access. A misbehaving model can direct the harness
  to send data anywhere it can reach, so this VM's nono network policy
  is an allowlist of specific hosts, not the general 80/443 access of my
  other VMs. That allowlist is security policy. nono 0.78's
  `--allow-domain` (a filtering proxy with a domain allowlist) looks
  like the mechanism.
* It refuses inbound connections from the other VMs on the UTM network.
* Sensitive data moves in and out on encrypted USB sticks, passed
  through by UTM directly to the VM. A LUKS stick can't be read by
  macOS, so it won't auto-mount on the host.
* goose and pi have no equivalent of Claude Code's PreToolUse hooks, but
  `vm-setup.sh`'s global commit-msg hook checks their commit messages,
  and `check-prose-style --text` can check any other text they produce.
* A nono grant binds to a file's inode when the sandbox starts, so a
  file replaced afterward stays denied until the sandbox restarts
  (`nono why` reports `stale_file_grant`). For example,
  `git config --global` replaces `~/.gitconfig`, so restart a harness's
  sandbox after running it or `vm-setup.sh`.

### Inference engine

* llama.cpp's upstream prebuilt macOS binary (`llama-server`). No
  Python, Homebrew, or compiler on the host. Use upstream builds:
  they use the M5's Metal 4 tensor API (GPU neural accelerators), which
  makes prompt processing 2.6x faster here; LM Studio's bundled
  llama.cpp reportedly doesn't enable it
  (https://github.com/lmstudio-ai/lmstudio-bug-tracker/issues/2040).
* llama-swap (https://github.com/mostlygeek/llama-swap) in front of a
  single llama-server. Its config file maps each model name to that
  model's `llama-server` command line (with per-model settings), so
  harnesses see a stable list of model names on one port. It loads
  the requested model on demand, one at a time, and can unload it after
  a timeout. llama-swap listens on 127.0.0.1 on the tunneled port; each
  backend `llama-server` listens on one fixed localhost port (hard-coded
  in each model's command and its `proxy` URL, instead of llama-swap's
  default dynamic `${PORT}`; verify this works). Turn on its API key.
  See "Alternatives considered" for why not llama-server's own router
  mode.
* Releases (decided 2026-10-19): rather than pinning llama.cpp and
  llama-swap forever, which would miss improvements and security
  fixes, `host-setup.sh` installs the newest release of each that's at
  least `INFER_COOLING_DAYS` (7) old, so others have had time to notice
  a bad or malicious release. For llama.cpp, that's the newest stable
  `vX.Y.Z` release, then the build (`bNNNNN`) its `nightly-tag.txt`
  names; llama.cpp also publishes a build for nearly every commit, as
  prereleases. Each download is checked against the SHA-256 GitHub
  publishes for it. GitHub release files can be replaced later (these
  repositories don't use immutable releases), and that SHA-256 is of
  the current file, so a file is accepted only if it was last changed
  within an hour of its release's publication, or not for the whole
  cooling period. A floor (`LLAMA_CPP_MIN`, `LLAMA_SWAP_MIN`: the
  releases we last tested) keeps it from going back to an older
  release, and stops mattering once a newer one is old enough. A pin
  (`*_PIN`) holds back from a release that breaks something, and
  `host-setup.sh` warns while one is set. Going back from the tested
  b11721 to v0.6.0 (b11429) would have been a small loss: all our
  flags and Qwen3.8-27B's architecture (`qwen35`) are in both, but
  v0.7.0 (b11669) has Metal fixes and a stack-overflow fix, so the
  floor is v0.7.0.
* Locations (decided 2026-10-19), conventional rather than under a
  "bulkhead" name, since others might use these tools too: each
  release in its own root-owned directory, `/opt/llama.cpp/BUILD` and
  `/opt/llama-swap/VERSION`, which the daemon's files name (so a new
  release changes them and restarts the engine), with a `current`
  symlink recording what's installed; the commands linked through it
  into `/usr/local/bin`; the service's
  own config in `/usr/local/etc/infer` (`llama-swap.yaml`, `infer.sb`);
  the daemon `local.infer`; and the sudoers rule
  `/etc/sudoers.d/infer`. `host-setup.sh` refuses to install unless
  every directory the daemon depends on is root-owned and writable
  only by root, since otherwise a process running as me could swap in
  its own engine and see the secure VM's prompts.
* Settings:
  * Q8_0 models by default (nearly lossless; see "Test results");
  * `-fa on` and the default physical batch size (`-ub` 512);
  * `--api-key`, sent by the harnesses, and restricted CORS if
    llama-server allows it. Without them, any web page open in a browser
    on the Mac could send requests to the engine on 127.0.0.1 and read
    the replies, since the browser itself is local;
  * `--parallel 1`, instead of the default 4 slots sharing one KV cache;
  * `/slots` turned off (check the exact flag);
  * the prompt cache off for now (`--cache-ram 0`; the default is 8192
    MiB). It keeps copies of earlier prompts' KV state in ordinary,
    swappable memory (see "Keeping data off the SSD"). With one agent
    it barely helps: the slot's own KV cache already gets reused when
    each turn extends the previous one. It helps a lot with several
    agents taking turns on fewer slots, since each switch otherwise
    reprocesses the whole context. If we run several agents at once,
    turn it on, or use more slots (`--parallel N --kv-unified`, so they
    share one context pool; without `--kv-unified` each slot gets only
    `--ctx-size`/N). Choose `--parallel`, `--kv-unified`, and
    `--cache-ram` together, as one per-model setting in `config.sh`.
    Either way, a mode switch restarts the engine to discard all of it;
  * no features that persist state to disk (e.g., `--slot-save-path`),
    and logging at the default level, kept in llama-swap's memory and
    collected in the VM (see "Keeping data off the SSD");
  * never `--tools` or `--mcp-servers-*`: llama-server's built-in agent
    tools can read and write files and run shell commands, and its docs
    say "do not enable in untrusted environments" (both are off by
    default);
  * an explicit `--ctx-size` (the context window), chosen per model:
    being able to process a lot of data when needed matters more than
    speed, since compaction degrades results. For Qwen3.8-27B, use its
    native maximum, 262,144 tokens. It's a hybrid model: only 16 of its
    64 layers are full attention (the other 48 use linear attention,
    with a small fixed-size state), so its KV cache is 64 KiB per token
    at f16 (2 x 16 layers x 4 KV heads x 256 x 2 bytes), i.e., 16 GiB
    at 262,144 tokens, about 43 GB with the weights. llama-server
    reserves the whole KV cache when it loads the model, whether or not
    it's used. Speed only drops when a conversation actually gets long
    (in Phase C, generation went from 18.4 tokens/s at an empty context
    to 13.5 at 32k). Set it explicitly anyway: this build otherwise
    sizes itself to nearly all memory Metal can use, which squeezes the
    VMs and macOS toward swap;
  * define each model once, in `config.sh` (which the Mac and the VMs
    both read): its name, file, context window, and maximum reply
    length. `host-setup.sh` generates llama-swap's config from that
    (`--ctx-size`), and `vm-setup.sh` generates pi's `models.json`
    (`contextWindow`, `maxTokens`), so they can't disagree. That's
    `config.sh`'s `INFER_MODELS`, read by `common.sh`'s
    `infer_llama_swap_yaml` and `infer_pi_models_json`.
* To try in real use: speculative decoding with Qwen3.8-27B's MTP heads
  (`--spec-type draft-mtp`; Unsloth publishes them as
  `MTP/mtp-Qwen3.8-27B-Q4_0.gguf`, 1.4 GB), and the n-gram methods,
  which help when output repeats existing text (e.g., code edits).
* Never configure a llama-swap model whose `proxy` points off the Mac.
  llama-swap can forward requests to remote services (its example
  config forwards to OpenRouter and a Tailscale address), and one such
  line would send prompts out. The sandbox's outbound block is a second
  layer, not the plan.
* Power and cooling: for sustained use, charge the Mac over MagSafe
  with its own adapter, not from the monitor's USB-C. The monitor gave
  65 W, and under a long load the battery drained even while plugged
  in. The 14-inch M5 Max's 96 W adapter gives 94 W, and Apple doesn't
  say the 14-inch draws more, so a bigger adapter wouldn't help. Plug
  in MagSafe alongside the monitor; the Mac takes the stronger source.
  (`system_profiler SPPowerDataType` shows the negotiated wattage.)
  Keep the Mac on a stand, not a soft surface, so air reaches its
  underside: the 14-inch case's cooling limits sustained speed too.
  Measurements may miss the worst cases, so the watcher (see "Kill on
  sleep") also switches to Low Power Mode when the battery runs low. I
  expect Low Power Mode to cost prefill more than generation, since
  generation is mostly limited by memory bandwidth; measure it with
  llama-server's tokens/s after a long run.
* Energy Mode is set per power source, and this Mac already has
  `powermode 2` (High) on AC and `0` (Automatic) on battery
  (`pmset -g custom`), so unplugging leaves High Power Mode without
  any help. The watcher handles only a low battery, on either source:
  * Below 30%: remember both sources' `powermode`, then set Low on both
    (`pmset -a powermode 1`).
  * At 40% or more and plugged in: if the watcher set Low and both are
    still Low, restore the remembered values; if I changed either by
    hand meanwhile, forget them and change nothing. It only undoes its
    own changes.
  * The 10-point gap keeps it from flapping. 40% is low enough to let
    a task finish at full speed once charging catches up.
  * `pmset` needs root, so this uses sudoers rules for exact commands of
    Apple's tool, no root code of ours: `pmset -a powermode 1` and the
    six restores (`-b` or `-c`, each with 0, 1, or 2). I believe 1 is
    Low and 0 Automatic; check before relying on it.
  * The watcher reads the battery level, charging state, and adapter
    through IOKit's power-source notifications, which don't need root.
  * Not built: if Low Power Mode isn't enough, pause `llama-server` at a
    critical level (e.g., 10% and still draining) with SIGSTOP and
    resume with SIGCONT (e.g., at 20%). It keeps the model, KV cache,
    and request in memory. It's about 20 lines plus sudoers rules
    running `pkill -STOP -x llama-server` and `-CONT` as `_infer` (not
    root), but needs testing: the sleep handler must send SIGCONT
    before unloading, a `llama-server` started during a pause isn't
    stopped, and pi, llama-swap, and the tunnel must survive a long
    pause without timing out.

### Image generation

* Image models run under stable-diffusion.cpp's server, as llama-swap
  entries like any other model (e.g., `flux2-dev`, `flux2-klein`, each
  with its own command line). stable-diffusion.cpp is MIT-licensed C++
  from the same ggml family as llama.cpp, publishes a prebuilt macOS
  arm64 build (36 MB), and supports FLUX.2-dev and FLUX.2-klein, so it
  needs no Python and runs as `_infer` under the same sandbox. (I
  haven't confirmed the macOS build includes its server; llama-swap's
  support for its API suggests it does.)
* llama-swap routes the OpenAI-style image endpoints
  (`/v1/images/generations`, `/v1/images/edits`) and stable-diffusion.cpp's
  own (`/sdapi/v1/txt2img`, `/sdapi/v1/img2img`) by model name, the same
  way as text.
* I can keep many image models and switch among them, one loaded at a
  time, just as with LLMs.
* First image model: FLUX.2-klein 4B, for personal, non-commercial
  play (I'd use LF's Gemini license for LF work). It's the only
  candidate with an open source license (Apache-2.0), about 9 GB at
  Q8_0, fast (designed for 4 steps), and well known (out since January
  2026). Its files, in the `flux2-klein-4b` subdirectory: the image
  model (`flux-2-klein-4b-Q8_0.gguf`, leejet), the Qwen3-4B text encoder
  (`Qwen3-4B-Q8_0.gguf`, unsloth), and the VAE from its own repository
  (`vae/diffusion_pytorch_model.safetensors`, Black Forest Labs, in the
  diffusers layout). stable-diffusion.cpp's docs point to FLUX.2-dev's
  `ae.safetensors` instead, which needs a Hugging Face login and is
  under FLUX.2-dev's non-commercial license. I believe
  stable-diffusion.cpp's diffusers VAE converter
  (`convert_diffusers_vae_to_original_sd1`) handles klein's file, but
  that's less certain than it looks: klein's `vae/config.json` says
  `AutoencoderKLFlux2`, a FLUX.2-specific variant of the diffusers VAE,
  while that converter is the generic Stable Diffusion one, so it may
  not map FLUX.2-specific parts. If it doesn't load, fall back to
  `ae.safetensors`.
* Other candidates, checked 2026-10-18 (all open-weight; sizes at
  Q8_0 including the text encoder and VAE): FLUX.3 Image Klein (about
  11 GB; FLUX Kommunity license; vendor claims lead open-weight models,
  but early reception is mostly skeptical, e.g., anatomy problems),
  Qwen-Image 2.1 (about 18 GB; Qwen research license; 20th on Artificial
  Analysis's text-to-image leaderboard), and FLUX.2-dev (about 60 GB, or
  35 GB at 4-bit; non-commercial; the strongest earlier, but large and
  slow). No source compared them all; revisit FLUX.3 Image Klein once
  independent reviews arrive.
* Turning typed text into an image needs only the image model: it has
  its own text encoder, which stable-diffusion.cpp loads as part of it.
  (FLUX.2-dev's encoder is large; I believe it's a roughly
  24B-parameter language model, so the whole model needs more than the
  19-27 GB of its quantized image part, but still fits on its own.)
* By default llama-swap swaps: requesting an image model unloads the
  LLM, and the next text request reloads it, losing its cache, so a long
  conversation is processed again (a minute or more). That's fine for
  typing a description and getting an image. If an LLM starts driving
  image generation (writing prompts, or making images mid-conversation),
  use llama-swap's `matrix` to keep both loaded; memory allows it (Q8_0
  at 27 GB plus an image model, within the roughly 107 GB Metal can use),
  but each concurrent backend needs its own port and sandbox allowance.
* Every backend, text or image, uses the same fixed localhost port,
  since only one runs at a time, so the sandbox needs only one outbound
  allowance.
* Image clients: goose and pi are text agents, so call the image
  endpoint through the tunnel with a client in the secure VM, from
  `curl` up to a web UI.

### The `_infer` account

* A hidden role account, created by `host-setup.sh` with `dscl`: its own
  `_infer` group, the lowest free ID from 400 to 499 for both (everything
  else refers to it by name), `/usr/bin/false` as its shell,
  `/var/empty` as its home, a disabled password, `IsHidden`, and no
  Secure Token. It isn't in `staff`, so `staff`-readable files aren't
  readable by it.
* Every account, `_infer` included, is in the File Sharing groups
  (`com.apple.sharepoint.group.N`, which nest `everyone`) and
  `_lpoperator` (which nests `localaccounts`). `host-setup.sh` warns
  only about groups `nobody` isn't in.
* It never logs in. A GUI session would bring Spotlight indexing, saved
  application state, crash reports, a keychain, and more RAM use.

### Engine control

* llama-swap (and the `llama-server` it starts) runs as a launchd
  daemon (`/Library/LaunchDaemons`, `UserName=_infer`) under the host
  sandbox below.
* No code of ours runs as root (decided 2026-10-19; I don't want a lot
  of root-privileged code). launchd, which is Apple's, starts the daemon
  as `_infer` from a root-owned plist; installation needs `sudo` once.
  Existing tools cover each job:
  * switching models: request a model by name (llama-swap);
  * unloading a model (freeing it, its KV cache, and its prompt cache by
    stopping llama-server): llama-swap's `POST /api/models/unload`, with
    the API key, no root needed;
  * restarting llama-swap, for `infer-access`: `launchctl kickstart -k
    system/<label>`, allowed without a password by one sudoers rule for
    exactly that command (one fixed Apple command, not code of ours).
    When launchd stops the job, it also stops the job's other processes,
    i.e., the backend `llama-server`. A restart also clears llama-swap's
    in-memory log; unloading doesn't;
  * status: `curl` to `/health` and llama-swap's `/running`, no root
    needed.

### Reaching the engine and switching access

The engine listens only on the Mac's 127.0.0.1, and VMs reach it only
through SSH reverse tunnels my host account opens
(`ssh -N -R <port>:127.0.0.1:<port> <vm-name>`, using the
`~/.ssh/config` that `host-setup.sh` builds). So "who can reach it" is
just "which VMs have a tunnel"; switching never changes the engine's
listen address or a firewall rule. Machines outside the Mac can never
reach it, and a tunnel's port binds only to its VM's own loopback.

* One host command, `infer-access.sh` in this repo (like
  `host-secrets.sh`), run as me:

  ```
  ./infer-access.sh secure    # only the secure VM
  ./infer-access.sh shared    # every other running VM, but NOT the secure VM
  ./infer-access.sh off       # no VM
  ./infer-access.sh status    # recorded mode and tunnels
  ```

* Each mode change closes every tunnel, resets the engine
  (`launchctl kickstart -k`, discarding the KV cache, prompt cache,
  slots, in-flight requests, and llama-swap's in-memory log, which
  holds metadata such as which model ran, when, and token counts), opens tunnels for the new mode, and records
  the mode in a state file so `status`, reboots, and wake agree. The
  reset always happens, between closing and opening, so nothing from
  the secure VM is left in the engine when other VMs gain access.
* Modes are exclusive. Sharing one engine between the secure VM and
  other VMs at the same time would put the secure VM's prompts in the
  process they query (the `/slots` and prefix-cache timing concerns). A
  mode including both would be a deliberate fourth mode, added only if
  needed.
* "shared" gets its VM list from `host-backend.sh`'s `enumerate_guests()`,
  minus the secure VM, when it runs: a VM started later gets no tunnel
  until I rerun `infer-access.sh shared` (decided 2026-10-19, rather
  than a watcher running all the time). Each tunnel is a per-user
  launchd agent (`local.infer-tunnel.VM`) running `ssh -N -R`, with
  `KeepAlive`, `ExitOnForwardFailure`, and `ServerAlive*`, so it
  reconnects after a VM reboot or the Mac's sleep, and comes back after
  the Mac reboots.
* Before resetting the engine, it waits until no ssh forwards the
  engine's port, including one started by hand, and refuses to go on if
  one does; if the reset fails while the engine is running, it opens no
  tunnels.
* `config.sh` settings: `INFER_SECURE_VM` (empty until the secure VM
  exists; "secure" refuses to run until it's set) and `INFER_PORT`,
  replacing the `ENABLE_INFERENCE_SSH_TUNNEL` placeholder.
* In a VM with a tunnel, any process that can reach that loopback port
  can use the model, including a sandboxed agent if its nono policy
  allows that port.

### Host sandbox (built-in macOS only)

The engine should have almost no permissions, using only what macOS
provides, so the host gets no extra software.

**Current decision (2026-10-18): stop at Phase B1 for now.** Use the B1
profile (allow by default; deny outbound IP network, writes outside
allowed directories, and reads under `/Users` except the model and
engine directories) plus the three allowances below (the Metal shader
cache, `/dev/dtracehelper`, and outbound to the backend port only), as
the trial does. It covers the main goals (no outbound network, no
reading my files, no writes outside allowed places) in about 35 lines
I understand. It also limits what a compromised engine can learn about
other accounts and processes:

* it can't read `/private/etc/passwd`, `/private/etc/group`, or the
  login record `/private/var/run/utmpx` (what `who` reads);
* `(deny process-info*)`, allowing only `(target self)` and
  `(target same-sandbox)`, blocks detailed queries about other
  processes;
* the sandbox refuses to run setuid programs such as `/bin/ps`.

Accepted leftovers: it can still list every process's name, PID, and
owner (that comes through `sysctl`, not `process-info`; blocking
`kern.proc` could break llama-swap's tracking of its child), and look
up other accounts through the directory service (what `dscl` and `id`
use, revealing e.g. my account name and full name), which I left open
because libraries look up the current user. Neither matters much while
the engine can't send anything out. In normal use the model can't do
any of this anyway: it only produces text, and its tool calls are run
by the harness in the VM; these limits are for a compromised engine
(e.g., a crafted model file or request exploiting a parser bug, or a
tampered binary). A strict `(deny default)` profile, described next, is
deferred. If I want one, the leading option is nono's prebuilt macOS
binary (`nono-v0.80.0-aarch64-apple-darwin.tar.gz`, no Homebrew
needed) rather than hand-building one: its `(deny default)` profiles are
maintained against macOS changes, and its `--allow-gpu` grants Metal
through `(allow iokit-open (iokit-user-client-class
"AGXDeviceUserClient"))` plus `(allow iokit-get-properties)`. A web
search (2026-10-18) found no published, tested `(deny default)`
profile for llama.cpp or other Metal inference servers.

The strict profile, if built:

* Seatbelt via `/usr/bin/sandbox-exec -f infer.sb ...` around llama-swap,
  with a root-owned SBPL profile starting from `(deny default)` and
  allowing only:
  * reading the model directory, the llama.cpp and llama-swap
    directories, and the system libraries and frameworks they need;
  * writing only to `_infer`'s own Metal shader cache
    (`.../C/com.apple.metal` under its `/var/folders` directory:
    compiled GPU code, not prompt data; denying it costs about 3 s per
    model start), and `/dev/dtracehelper` (the dynamic linker
    registering DTrace probes; harmless, and denying it fills the
    denial log with noise), plus `/dev/null`;
  * listening on 127.0.0.1 on the two ports (llama-swap's and the
    backend's);
  * outbound only to 127.0.0.1 on the backend's port, for llama-swap.

  Child processes (the backend `llama-server`) inherit it, so the
  backend could also connect to that one port, i.e., itself, but
  nothing else. Rules later in a profile override earlier ones
  (confirmed in Phase B1). `sandbox-exec` is deprecated and SBPL is
  undocumented, but it still works and is widely used (Chrome, Bazel,
  several AI coding tools); nono's macOS backend uses the same kernel
  mechanism.
* Deny-by-default also enforces the SSD goal for the engine itself: an
  unexpected write fails instead of landing on the SSD. The remaining
  gaps are system services outside the sandbox: Metal's shader compiler
  cache (compiled kernels, not prompt data), crash reports (I believe
  backtraces and registers, not memory), and unified logging (llama.cpp
  doesn't use it).
* SBPL can allow localhost to one port or to all ports, not a range, and
  allowing all would let the engine reach every localhost service (e.g.,
  CUPS on 631, maybe the secrets server). That's why the backend uses
  one fixed port.
* launchd plist keys: `UserName`/`GroupName`; `WorkingDirectory`,
  `HOME`, and `TMPDIR` of `/var/empty` (not writable);
  `StandardOutPath` and `StandardErrorPath` of `/dev/null`; `Umask` 077;
  and
  `HardResourceLimits` with `Core` 0, so a core dump (process memory,
  including the KV cache) can never be written.
* TCC adds a layer: a daemon with no privacy grants can't read protected
  folders (Documents, Desktop, ...).
* Maybe pf as a second network layer (`block out ... user _infer`), if
  macOS's pf honors `user`.
* Fallback, if `(deny default)` turns into an endless list of Metal
  allowances: allow by default but deny outbound network, writes
  outside the allowed places, and reads of `/Users` and other sensitive
  paths. That's weaker, but still covers the goals that matter most.

### Keeping data off the SSD

* The model weights and KV cache are in wired memory, which can't be
  swapped (see "Test results"). Size things so macOS never needs swap.
* **Where conversation data can end up**, mainly the KV cache (which
  holds a processed form of everything in the context):
  * While the engine runs, only root and the engine can read it. A
    malicious root on the Mac is out of scope: we've lost anyway. GPU
    isolation bugs are possible (LeftoverLocals, CVE-2023-4969, leaked
    GPU local memory between processes on Apple GPUs; patched). No API
    endpoint dumps the cache (`/slots` is off, no `--slot-save-path`),
    but with a prompt cache or several slots, a client with the API key
    could tell by timing whether someone recently sent a given prefix;
    in secure mode only the secure VM can reach the engine.
  * After it stops, the kernel zero-fills the freed pages before giving
    them to any other process.
  * The prompt cache (off for now) is ordinary memory, so it can go to
    swap, which is encrypted and deleted at boot. That would be an
    acceptable risk if we turn it on for several agents.
  * Wired memory still goes into the sleep image, which is why we
    unload the model before sleep. If some leaks in anyway (e.g., the
    watcher fails), overwriting won't reliably remove it, since an SSD
    writes new versions to fresh blocks and erases old ones whenever it
    gets around to it. What protects it is encryption: on Apple Silicon
    the storage controller encrypts everything on the internal SSD with
    keys the Secure Enclave protects, and FileVault ties them to my
    password, so stale blocks are ciphertext to anyone without the
    password. The remaining risk is someone with the Mac *and* my
    password reading free space as root before it's TRIMmed or reused,
    which is close to the out-of-scope malicious root. Crypto-erase
    ("Erase All Content and Settings") removes it for certain. Open
    question: does macOS on Apple Silicon also encrypt the hibernation
    image with its own discarded key, as Intel Macs did? Check Apple's
    Platform Security guide.
* Swap is acceptable for confidentiality if it's encrypted and a reboot
  makes it unreadable. Apple's Platform Security guide (August 2026,
  "Role of Apple File System") says the VM volume "is unencrypted and is
  used by macOS for storing encrypted swap files", and
  `sysctl vm.swapusage` here shows `(encrypted)`. I couldn't find an
  authoritative source saying the key changes at each boot; I believe it
  does, since swap is never read back after a reboot. We still avoid
  swap, to avoid SSD writes. What could be swapped: the engine's
  ordinary CPU memory (requests, tokens, output) and the VMs' RAM.
* The engine writes nothing to disk (decided 2026-10-19, replacing a
  RAM disk). The tests showed it writes only the Metal shader cache and
  `/dev/dtracehelper`, so instead of giving it a RAM disk, give it
  nowhere to write: the sandbox denies all writes except those two and
  `/dev/null`; `HOME` and `TMPDIR` are `/var/empty` (not writable); and
  llama-swap's output goes to `/dev/null`, which launchd can safely open
  directly. If a component ever needs to write a file, the sandbox
  denies it and the denial log shows it; then reconsider.
* **There are still logs, just in the guest, not the host.** llama-swap
  keeps recent logs in memory and streams them as two streams:
  `/logs/stream/proxy` (its own lines, e.g., model loads and unloads;
  in v265 plain `/logs/stream` is only this one) and
  `/logs/stream/upstream` (llama-server's output, e.g., load details
  and each request's token counts and timing, with no prompt text). In
  the VM, the `infer-logs@proxy` and `infer-logs@upstream` systemd user
  services read them through the tunnel
  (`curl -N .../logs/stream/STREAM?no-history`, so a reconnect doesn't
  record lines twice), drop slot bookkeeping and unused-tensor warnings
  (keeping three timing lines per request: prefill, generation, and
  total), and write the rest to the journal, on the VM's
  encrypted disk next to the harness's own logs; read them with
  `journalctl --user -u 'infer-logs@*'`. Lines from while they're
  disconnected stay only in llama-swap's memory, readable with
  `curl .../logs` (proxy only) or `.../logs/stream/upstream` until
  llama-swap restarts. In the secure VM, only the secure VM collects
  them, since only it has the tunnel in secure mode.
* The RAM disk prototype worked (see "Test results") and stays
  documented there, in case a component needs to write files later. It
  needed a root daemon at every boot, which the no-write design avoids.
* Kill on sleep (lid-close sleep and hibernation), without root: a small
  launchd agent running as me registers with IOKit's
  `IORegisterForSystemPower` (which doesn't need root). On
  `kIOMessageSystemWillSleep` it calls llama-swap's
  `POST /api/models/unload` with the API key, which stops llama-server
  (freeing the model, its KV cache, and its prompt cache), waits for
  that to finish, then calls `IOAllowPowerChange` (macOS waits up to
  about 30 seconds). llama-swap itself keeps running, holding no
  conversation data, only its in-memory log (metadata). AppKit's sleep
  notification doesn't delay sleep, so it would race with the sleep
  image. Built (2026-10-19) as `infer-watch.c`, a C program of about
  200 lines that only runs a shell hook (`infer-watch-hook`) and waits
  for it; the decisions are all in the hook. `host-setup.sh` builds it
  with Apple's Command Line Tools, since I don't know of a trusted,
  maintained prebuilt tool
  for Apple Silicon that waits for its script before acknowledging
  sleep. Before sleep, the hook:
  * first closes the tunnels (`launchctl bootout`, keeping
    `infer-access.sh`'s plists), so no VM can load the model again
    between the unload and the sleep;
  * unloads the model and waits until no `llama-server` runs;
  * if it's still running after 8 seconds, restarts the engine with the
    existing `kickstart` sudoers rule.

  After waking, it reopens the tunnels whose plists are there, so the
  mode stays what `infer-access.sh` last set; the next request loads
  the model again. infer-watch gives the sleep hook 25 seconds and
  every other hook 10, since hooks run one at a time and a slow one
  could delay the sleep hook. It waits 2 minutes after it starts
  before doing anything, so if it misbehaves I have time to stop it
  (`launchctl bootout gui/$(id -u)/local.infer-watch`; killing it isn't
  enough, since launchd restarts it). Each restart waits again, which
  also slows any crash loop. A sleep during that wait gets no hook.
* FileVault stays on as the backstop. Accepted, and to be documented:
  the secure VM's RAM, including its LUKS master key and decrypted data,
  ends up in the host's sleep image; FileVault is what protects that.

### Models

* `/Users/Shared/models`: owned by my account, mode 755, model files
  read-only (444), excluded from Time Machine. Readable by `_infer` but
  not writable by it, and downloaded only once.
* `host-setup.sh` downloads each model in `config.sh`'s `MODEL_DOWNLOADS`
  (URL, the publisher's SHA-256, license) whose file is missing: to
  `FILE.partial` first, deleting it and stopping on a SHA-256 mismatch.
  `SHA256SUMS` (check with `shasum -a 256 -c SHA256SUMS`) and
  `SOURCES.tsv` (source URL, license, date added) record each file, and
  `README.txt` describes the conventions.
* Layout: single-file models directly in it, each multi-file model
  (multi-shard, or with an `mmproj` file) in its own subdirectory, the
  convention llama-server's `--models-dir` uses. An image model is
  usually several files (image model, text encoder, VAE), so each gets
  its own subdirectory, named by an optional fourth field in each
  `MODEL_DOWNLOADS` line.
* Current models: Qwen3.8-27B as Q8_0 (default) and UD-Q4_K_M, from
  unsloth, Qwen3-0.6B Q4_0 from ggml-org for quick tests, and
  FLUX.2-klein 4B for images; all Apache-2.0.
* Safety against malicious models:
  * GGUF or safetensors only, never pickle formats (`.bin`, `.pt`,
    `.ckpt`), which run code on load. `host-setup.sh` enforces this: it
    refuses URLs ending in `.bin`, `.pt`, `.pth`, `.ckpt`, `.pkl`, or
    `.pickle` before downloading, and deletes any download whose first
    bytes aren't GGUF (`GGUF`) or safetensors (an 8-byte header length,
    then `{`). As of 2026-10-18, all six model files pass (checked by
    their first bytes, not their names; the VAE's name
    `diffusion_pytorch_model.safetensors` is just diffusers' naming
    convention). Safe formats still need parsing, and a crafted file can
    exploit a parser bug, which is what `_infer` and the host sandbox
    contain;
  * never `trust_remote_code` (model-supplied Python) on the host; do any
    conversion (e.g., `convert_hf_to_gguf.py`) in a disposable VM and
    copy only the resulting weights;
  * a crafted GGUF can exploit engine parser bugs (llama.cpp has had
    some), which `_infer` and the host sandbox contain;
  * prefer well-known quantizers (ggml-org, unsloth, bartowski,
    mlx-community), and be more wary of "uncensored" derivatives from
    unfamiliar organizations;
  * a backdoored model steering the harness is handled by the secure
    VM's network allowlist, not by the engine.
* Memory budget: of 128 GB, a 16 GB secure VM, maybe one other 8 GB VM,
  and about 12-16 GB for macOS leave about 85-90 GB for weights plus KV
  cache. Metal's `recommendedMaxWorkingSetSize` here is 115448.73 MB
  (about 107 GiB), so the GPU memory limit doesn't need raising.

### Alternatives considered

* Engines: MLX (faster on small and mixture-of-experts models, but a
  Python stack), Ollama (now bundles MLX; more code to trust, its own
  model registry, cloud features), and LM Studio (closed source, hard to
  confine). Revisit MLX if I move to a mixture-of-experts model.
  llama-swap can also front other backends (e.g., an image engine).
* Model switching, besides llama-swap:
  * llama-server's own router mode: built in, so no extra software, but
    it starts each model's child server on a port the OS picks
    (`common_http_get_free_port()` in `tools/server/server-models.cpp`)
    and forwards requests to `127.0.0.1:<that port>`. So the sandbox
    would have to let the engine (a large C++ program parsing untrusted
    model files and requests) connect to any localhost port, letting a
    compromised engine reach every localhost service.
  * A single llama-server with no switcher: the tightest (no outbound
    network at all, no extra software), but switching models means
    editing the daemon's arguments and restarting it, i.e., writing and
    maintaining our own control script (the `infer-ctl` an earlier
    draft had), and harnesses can't switch by name.
* About llama-swap (checked 2026-10-18): MIT-licensed Go, written almost
  entirely by Benson Wong (GitHub `mostlygeek`, account since 2009,
  works at Tailscale); about 6,000 stars, about 80 contributors, very
  active (v265 on 2026-10-14), prebuilt macOS arm64 binary (22 MB).
  Reassuring: no published advisories or CVEs found; releases built by
  GoReleaser in GitHub Actions with actions pinned to commit hashes,
  plus a checksums file; memory-safe language. Concerns: one maintainer;
  no `SECURITY.md` and no OpenSSF Scorecard results; no signing or build
  attestations; about 158 Go modules (including Kubernetes client
  libraries, SQLite, and a pre-release Tailscale library); AI-assisted
  development. Acceptable because it runs inside the same sandbox as
  the engine: a compromised llama-swap could see prompts, as the engine
  can, but couldn't send them anywhere.
* Image engines besides stable-diffusion.cpp: mflux (MLX, so Python),
  Draw Things (an app), and ComfyUI (PyTorch, the heaviest).
* No Internet for the secure VM (rejected: it needs Internet; nono's
  allowlist limits it instead).
* nono on the host: first rejected because its recommended installation
  uses Homebrew, but it publishes a prebuilt macOS binary, so it's the
  leading option for a strict profile later (see "Host sandbox").
* Logging in to `_infer` via fast user switching, SSH to
  `_infer@localhost` with a forced command (turns on Remote Login, new
  LAN attack surface), and a launchd agent (needs a login session).
* Binding the engine to UTM's bridge interface with pf filtering by VM
  address (one misconfiguration exposes it on the LAN; VM addresses
  change).
* `hibernatemode 0` with standby off (loses everything if the battery
  dies, and I want hibernation), and relying only on FileVault (breaks
  the SSD goal).

## Implemented

* `host-setup.sh` creates the `_infer` role account, warns about
  unexpected groups, and sets up `/Users/Shared/models` with the model
  downloads. The old standard-user `_infer` from System Settings was
  deleted on 2026-10-18, with no leftover group memberships or FileVault
  entries.
* `vm-setup.sh` installs `check-prose-style --text` as a global
  commit-msg git hook.
* Written 2026-10-19, passed one forced sleep (see "Current state"): the sleep
  watcher (see "Kill on sleep" and "Power and cooling").
  `host-setup.sh` builds `infer-watch.c` into `~/bin/infer-watch` if
  there's a compiler (`xcode-select -p`), rebuilding only when the
  source differs from the copy it keeps as `~/bin/infer-watch.c`, and
  otherwise warns. It renders `infer-watch-hook.template.sh` into
  `~/bin/infer-watch-hook` and loads the `local.infer-watch` agent,
  which logs to `~/Library/Logs/infer-watch.log`. The sudoers file
  adds the seven `pmset` rules, checked with `sudo -n -k -l`.
  `config.sh` has `INFER_LOW_POWER_BELOW` (30) and
  `INFER_LOW_POWER_UNTIL` (40). If I change a mode by hand while it's
  Low, the hook leaves the modes alone until the battery is back to 40%,
  so it doesn't immediately undo my choice. Tested on mytux with fake
  `pmset`, `sudo`, `launchctl`, `pgrep`, and `curl`. On mytux,
  `tests/test_infer_watch.sh` (run by `ci.sh`) compiles the C against
  stand-ins for Apple's headers with strict gcc warnings and
  `-fanalyzer`, then runs it under ASan and UBSan with fake power
  events and working, failing, hanging, and missing hooks; it passes.
  It hasn't been compiled on the Mac yet.
* Written 2026-10-19, not yet run: the trial, moved into the repo.
  * `host-setup.sh` installs llama.cpp and llama-swap (see "Releases"
    and "Locations" under "Inference engine"); generates the API key
    (if missing) and llama-swap's config from `INFER_MODELS`; renders
    `infer.template.sb` and `infer.template.plist`; and installs them,
    root-owned, as `/usr/local/etc/infer/llama-swap.yaml` (readable
    only by `_infer`), `/usr/local/etc/infer/infer.sb`, and
    `/Library/LaunchDaemons/local.infer.plist`, plus the sudoers rule
    `/etc/sudoers.d/infer`. It stages each file as `FILE.new` and
    checks it on every run (llama-swap's `-validate`; the profile blocks
    outbound HTTPS, reading my home directory, and writes; `plutil
    -lint`; `visudo -c`), puts them in place only if all pass, and
    restarts the daemon only when one of its files changed. After a restart it checks for HTTP 401 without the key, and
    checks the sudoers rule by restarting again with `sudo -n -k`
    (which ignores, but keeps, sudo's cached password). It removes the trial's `local.infer-trial` daemon.
  * `vm-setup.sh`, on a VM with `~/.config/bulkhead/infer-api-key`,
    installs Node.js and pi (root-owned where `npm install -g` would
    put it, `/usr/local/lib/node_modules`, linked from
    `/usr/local/bin/pi`; npm runs as me, never as root). pi follows the
    same cooling rule, with `PI_MIN` (1.3.0) and `PI_PIN`, through
    npm's `--before`, which also limits its dependencies; for a floor
    or pin, `--before` is an hour after that release, since pi's
    sibling packages come out moments after it. It also installs
    `nopi` and `infer-logs` in `/usr/local/bin`,
    `infer-logs@.service` in `/etc/systemd/user`, and pi's
    `models.json` generated from `INFER_MODELS`, and removes the
    trial's copies in my home directory. A VM without the key skips
    all of it.

## Test results (2026-10-18 and 2026-10-19)

Run on the Mac with llama.cpp b11721. The scripts are throwaway, in
`,infer-test/`.

* **Metal works from a launchd daemon running as `_infer`, with no GUI
  session.** The daemon found `MTL0: Apple M5 Max` in about 3 seconds
  and was ready in about 1. With verbose logging (`-lv 4`), the log
  showed `offloaded 29/29 layers to GPU` and the KV cache in a Metal
  buffer; a CPU-only run decoded at 208 tokens/s versus 421 on the GPU
  (Qwen3-0.6B). Verbose logging didn't record the request text.
* **Speed** (Qwen3.8-27B, `-fa on`, `-ub` 512, tokens/s; no thermal or
  performance warnings during the run):

  | | Q8_0 (27 GiB) | UD-Q4_K_M (15.3 GiB) |
  | :---- | :---- | :---- |
  | Generation, depth 0 / 16k / 32k | 18.4 / 15.0 / 13.5 | 27.0 / 21.1 / 19.5 |
  | Prefill 2048, depth 0 / 16k / 32k | 615 / 489 / 408 | 660 / 475 / 400 |

  * The tensor API (`has tensor = true`) speeds prefill 2.6x: Q8_0
    prefill was 235 tokens/s with `GGML_METAL_TENSOR_DISABLE=1`.
  * Q8_0 generates at about 68-70% of Q4's speed, with nearly the same
    prefill, so Q8_0 is the default.
  * Physical batch sizes 1024 and 2048 were within noise of 512 at depth
    0 and slower at 16k and 32k.
  * Generation is near the hardware limit for a dense model (if memory
    bandwidth is about 550-620 GB/s, Q8_0's ceiling is about 20-23
    tokens/s), so another engine could gain at most roughly 10-25%.
    Prefill is compute-bound, so another engine might do better there;
    that's unmeasured, and matters less with the prompt cache.
  * In practice: a fresh 32k context takes about 70-80 s to process, a
    2k-token agent turn with the prompt cache about 4-5 s, and a
    500-token reply about 30-35 s.
* **Memory:** wired memory rose from about 3 GB to 29-33 GB whenever
  Q8_0 was loaded and fell back afterward, so the weights and KV cache
  are wired. Swap stayed at 0, the compressor under 300 MB, and the
  system-wide free percentage at 73% or more. `ioreg`'s
  `"In use system memory"` (class `AGXAccelerator`) reports GPU memory.
* **Account:** the new `_infer` has UID and GID 401, no Secure Token, and
  isn't a FileVault user.
* **File Sharing:** my Public folder is shared over SMB with guest
  access. If File Sharing is on, a local process (e.g., a compromised
  engine) could connect as a guest; the sandbox blocks outbound network,
  but I should turn File Sharing off if I don't use it, or at least turn
  off guest access.
* **Sandbox, Phase B1** (`,infer-test/phase-b1.sh`): a permissive
  profile (allow by default; deny outbound IP network, writes outside
  one directory, and reads under `/Users` except the model and test
  directories) passed all 12 self-tests, each checked both ways against
  an unsandboxed baseline. The macOS log confirmed the network denials
  (`network-outbound remote:*:443`, and `*:9` over IPv4 and IPv6); curl
  itself only says "Couldn't connect to server" either way. Under the
  sandbox, Metal and the tensor API worked at full speed
  (`has tensor = true`; Qwen3-0.6B prefill 26,254 versus 26,227
  tokens/s unsandboxed, generation 479 versus 481), and the `_infer`
  server daemon served a request at 448 tokens/s with no errors. The
  only denials that matter for the engine were writes to `_infer`'s
  Metal shader cache (Metal kept working without it, but startup took
  about 4 s instead of 1) and to `/dev/dtracehelper`; both are now
  allowed in the design.
* **First trial** (`,infer-test/trial.sh` on the Mac,
  `,infer-test/vm-pi-trial.sh` and `pi-local` on mytux), for
  non-sensitive use only, worked end to end:
  * llama-swap v265 ran as an `_infer` launchd daemon under the B1
    profile plus the three allowances, with `Core` 0 and `Umask` 077.
    All six self-tests passed, including outbound to the backend port
    allowed and to the port next to it denied. A request without the
    API key got HTTP 401. The macOS log showed no sandbox denials for
    llama-swap or llama-server.
  * Through the SSH tunnel from mytux, Qwen3-0.6B ran at 289-411
    tokens/s, and Qwen3.8-27B (Q8_0) answered correctly at 18.5
    tokens/s, 11 s including loading.
  * pi 1.3.0 (installed with `npm --ignore-scripts`, pinned) worked
    against llama-swap through `~/.pi/agent/models.json` as an
    `openai-completions` provider. pi's own llama.cpp provider expects
    llama-server's router mode, not llama-swap. `pi-local` runs it
    under nono's `nolabs-ai/pi` profile through `anon-access`, with
    `PI_OFFLINE=1`, `PI_SKIP_VERSION_CHECK=1`, and `PI_TELEMETRY=0`. It
    then works with the full 262,144-token context.
  * pi warns that `fd` and `ripgrep` are missing (offline mode stops it
    downloading them). `vm-setup.sh` now installs `ripgrep`. `fd` is
    skipped for now, since Ubuntu installs it as `fdfind` (another
    package uses the name `fd`) and pi runs without it.
  * Problems found and fixed in the trial script: the self-test's
    listener left the backend port briefly in TIME_WAIT, so llama-server
    couldn't bind it (now it waits); `launchctl bootstrap` right after
    `bootout` failed with "Bootstrap failed: 5: Input/output error"
    (now it waits until the label is unloaded); and the backend
    llama-server had no API key and allowed all CORS origins, so any
    web page in a browser on the Mac could have queried it directly
    (now `--cors-origins http://cors.invalid`, an origin no page can
    have).
  * The account and process hardening (see "Host sandbox") passed its
    self-tests: inside the sandbox, `/etc/passwd`, `/etc/group`, and
    `who` were blocked, and `/bin/ps` (setuid) wouldn't run, each
    checked against an unsandboxed baseline. A sandboxed `pgrep` still
    listed root processes (e.g., `logd`, `configd`), so the process
    list stays visible, as accepted. The first version of these tests
    was misleading: `ps` couldn't run at all, and `pgrep -x launchd`
    finds nothing even unsandboxed, so "can't see launchd" proved
    nothing; the tests now use `configd`, and report the visible
    process list as a known, accepted result. With the hardening,
    llama-swap and llama-server still ran with no sandbox denials.
  * A RAM disk prototype (later replaced by the no-write design; see
    "Keeping data off the SSD") worked: `infer-ramdisk`, run as root at
    boot by a `local.infer-ramdisk` launchd daemon, created a 256 MB RAM
    disk on `/private/var/infer-ram` (`hdiutil attach -nomount
    ram://...`, `newfs_hfs`), mounted `nodev, nosuid, noatime,
    nobrowse`, owned by `_infer` (mode 700), with a root-owned mount
    point underneath; `infer-ramdisk --check` (a mounted disk image
    whose image path is `ram://...`) accepted it and rejected a plain
    directory; and `infer-start`, run by the engine's daemon as
    `_infer`, refused to start without it, then started llama-swap with
    its log, `HOME`, and `TMPDIR` there, with no sandbox denials. Lessons
    if it's ever needed again: don't use launchd's `StandardOutPath` for
    a file on the RAM disk (launchd opens it before any check, so with
    the RAM disk missing it lands on the SSD); keep any script root runs
    root-owned; and check that the volume honors ownership. Spotlight hasn't indexed it:
    `mdutil -s` says "unknown indexing state" (no index), there's no
    `.Spotlight-V100` directory, and `mdfind -onlyin` finds nothing.
    `mdutil -s` must run as root, since only `_infer` can enter the
    directory.

* **No-write trial** (2026-10-19, `,infer-test/trial.sh`): with the
  profile allowing writes only to the Metal shader cache,
  `/dev/dtracehelper`, and `/dev/null`, and `HOME`, `TMPDIR`, and the
  working directory set to `/var/empty`, all self-tests passed (writes
  to `/Users/Shared/infer-test` and `/private/var/tmp` denied, to
  `/dev/null` allowed), llama-swap was ready in about 1 s, and the
  chat ran at 297 tokens/s. Unloading through the API left no model
  loaded and stopped llama-server; `launchctl kickstart -k` restarted
  llama-swap and cleared the earlier session from its in-memory log.
  The only sandbox denials were llama-swap reading
  `/private/etc/passwd` (blocked by the hardening); I believe that's
  Go's standard user lookup, and llama-swap worked fine without it.
  Removing the RAM disk prototype needed `umount` before
  `hdiutil detach` (it was mounted with `mount(8)`, not Disk
  Arbitration, so `hdiutil detach` alone said "Resource busy"); nothing
  had it open, and stopping the daemon had stopped llama-server too.

## Remaining work

In order. Steps marked (sudo) need me, since the AI doesn't run sudo
here.

1. **Run and check the moved trial** (sudo; see "Implemented"; done
   2026-10-19): on the
   Mac, `./host-setup.sh` (then delete `/Users/Shared/infer-test` and
   `/Users/Shared/trial.sh`); on mytux, `./vm-setup.sh`, then
   `nopi --print 'Say hello in five words.'` through the tunnel,
   `journalctl --user -u 'infer-logs@*'`, and the macOS log for sandbox
   denials (`log show --last 10m --predicate 'sender == "Sandbox"'`).
   A second `./host-setup.sh` should say the engine is up to date.
2. **Sleep watcher** (sudo; partly done 2026-10-19): a forced sleep
   unloaded the model, the tunnel came back on wake, and the model
   reloaded on the next request (see "Current state"). We've put off
   the rest to step 8, since the other steps matter more now.
3. **Tunnels and `infer-access`**: written 2026-10-19; `shared` works.
   After step 1, stop the hand-started tunnel, run
   `./infer-access.sh shared`, and check `./infer-access.sh status`,
   `nopi` on mytux, and that a tunnel comes back after mytux
   reboots. It came back after the Mac slept (see "Current state").
4. **Secure VM**: create it with LUKS, run `vm-setup.sh`, set up goose
   and pi against the engine, write the nono allowlist (which hosts do
   they need?), and refuse inbound connections from other VMs.
5. **End-to-end checks**: nothing from `_infer` reaches the SSD (e.g.,
   `fs_usage` during a session), swap stays at 0 after a heavy session,
   and usability in real use, including MTP speculative decoding.
   Check that agent turns stay about as fast with `--cache-ram 0`
   (the earlier 4-5 s for a 2k-token turn was measured with the
   prompt cache on), using the timing lines in the VM's journal. With
   it off, a first turn of 2,004 prompt tokens and 55 output tokens
   took 5.6 s (prompt 756 tokens/s, output 18.45 tokens/s), but the
   cache can't help a first turn; check later turns in a long session.
6. **File Sharing**: turn it off, or at least guest access (my action).
7. **Documentation**: move the lasting parts into `architecture.md` and
   `README.md`.
8. **More sleep tests** (sudo), put off from step 2. I expect them to
   pass, and FileVault encrypts the sleep image anyway, but they
   haven't run:
   * The low-battery power modes (see "Power and cooling"). This is our
     own untested shell logic, so it's the likeliest to have a bug,
     but a bug would only leave the wrong power mode, and it's cheap to
     test: change the thresholds temporarily in `config.local.sh`
     rather than draining the battery. With both at 101, rerunning
     `host-setup.sh` should switch to Low; then with
     `INFER_LOW_POWER_UNTIL=0` (plugged in) it should restore the
     modes. Also check that 1 really is Low (`pmset -g custom`, and
     System Settings > Battery > Energy Mode).
   * A real lid close (on battery, or with the external display
     unplugged, since on this setup AppleClamshellCausesSleep is No).
     It sends the same `kIOMessageSystemWillSleep` as the forced
     sleep, so just check `infer-watch.log` after one happens in normal
     use. `tests/sleep-test.sh` covers it.
   * Forced sleep at critically low battery, the case where macOS
     hibernates and writes `/private/var/vm/sleepimage`. I believe it
     still sends the notification, but I don't know that it waits the
     full 25 seconds for the hook. Testing means draining the battery,
     so check the log if it happens in normal use. Also whether freed
     pages stay out of the sleep image (I believe macOS writes only
     in-use pages).
   * Whether UTM crashes on most sleeps (it crashed once, on
     2026-10-19). If it does, a sleep loses the VMs anyway, so the
     simpler answer is to avoid sleeping the Mac while VMs run.
   * The hook didn't run for the sleep after a DarkWake, nor for the
     DarkWake itself. I believe macOS doesn't send apps these for a
     DarkWake; that's fine, since the tunnels stay closed until a full
     wake.
9. **Maybe, later: a strict host sandbox**, most likely with nono's
    prebuilt binary (see "Host sandbox"). Check `has tensor = true`
    under it, since llama.cpp compiles a test kernel at startup and
    silently disables the tensor API if that fails, which would cost
    2.6x on prefill; also check whether pf honors `user` rules.
