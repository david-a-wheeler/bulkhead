# Local AI plan

This is the plan for running local AI models on my Mac for work on
sensitive data. It records the goals, the design we've settled on, what's
already implemented, what we've measured, and the work that remains. See
`architecture.md` for the overall bulkhead design this builds on; once
this is built, the lasting parts belong there.

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
* Router mode (`--models-dir`, on-demand loading by name,
  `--models-max 1`), with per-model settings in a preset INI file
  (`--models-preset`), so harnesses see a stable list of model names on
  one port.
* Settings:
  * Q8_0 models by default (nearly lossless; see "Test results");
  * `-fa on` and the default physical batch size (`-ub` 512);
  * `--api-key`, sent by the harnesses, and restricted CORS if
    llama-server allows it. Without them, any web page open in a browser
    on the Mac could send requests to the engine on 127.0.0.1 and read
    the replies, since the browser itself is local;
  * `--parallel 1`, instead of the default 4 slots sharing one KV cache;
  * `/slots` turned off (check the exact flag);
  * the prompt cache (`--cache-ram`, in RAM, 8192 MiB by default) stays
    on, since agent harnesses re-send mostly the same context; it
    retains earlier prompts, which is one reason a mode switch restarts
    the engine;
  * no features that persist state to disk (e.g., `--slot-save-path`),
    and logging at the default level, to the RAM disk.
* To try in real use: speculative decoding with Qwen3.8-27B's MTP heads
  (`--spec-type draft-mtp`; Unsloth publishes them as
  `MTP/mtp-Qwen3.8-27B-Q4_0.gguf`, 1.4 GB), and the n-gram methods,
  which help when output repeats existing text (e.g., code edits).

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

* The engine runs as a launchd daemon (`/Library/LaunchDaemons`,
  `UserName=_infer`) under the host sandbox below.
* I control it from my own account with one small command, e.g.,
  `infer-ctl use <model> | stop | restart | status | list`, allowed by a
  sudoers rule that permits exactly that command as `_infer`. With
  on-demand loading, harnesses just request a model by name and
  `infer-ctl` is rarely needed.

### Reaching the engine and switching access

The engine listens only on the Mac's 127.0.0.1, and VMs reach it only
through SSH reverse tunnels my host account opens
(`ssh -N -R <port>:127.0.0.1:<port> <vm-name>`, using the
`~/.ssh/config` that `host-setup.sh` builds). So "who can reach it" is
just "which VMs have a tunnel"; switching never changes the engine's
listen address or a firewall rule. Machines outside the Mac can never
reach it, and a tunnel's port binds only to its VM's own loopback.

* One host command, run as me:

  ```
  infer-access secure    # only the secure VM
  infer-access shared    # every other local VM, but NOT the secure VM
  infer-access off       # no VM
  infer-access status    # current mode and live tunnels
  ```

* Each mode change closes every tunnel, resets the engine
  (`infer-ctl restart`, discarding the KV cache, prompt cache, slots,
  and in-flight requests), opens tunnels for the new mode, and records
  the mode in a state file so `status`, reboots, and wake agree. The
  reset always happens, between closing and opening, so nothing from
  the secure VM is left in the engine when other VMs gain access.
* Modes are exclusive. Sharing one engine between the secure VM and
  other VMs at the same time would put the secure VM's prompts in the
  process they query (the `/slots` and prefix-cache timing concerns). A
  mode including both would be a deliberate fourth mode, added only if
  needed.
* "shared" gets its VM list from `host-backend.sh`'s `enumerate_guests()`,
  minus the secure VM. Each tunnel is a per-user launchd agent with
  `KeepAlive`, so it reconnects after a VM reboot or the Mac's sleep.
* New `config.sh` settings: `INFER_SECURE_VM` and `INFER_PORT`, replacing
  the `ENABLE_INFERENCE_SSH_TUNNEL` placeholder.
* In a VM with a tunnel, any process that can reach that loopback port
  can use the model, including a sandboxed agent if its nono policy
  allows that port.

### Host sandbox (built-in macOS only)

The engine should have almost no permissions, using only what macOS
provides, so the host gets no extra software:

* Seatbelt via `/usr/bin/sandbox-exec -f infer.sb ...`, with a
  root-owned SBPL profile starting from `(deny default)` and allowing
  only: reading the model directory, the llama.cpp directory, and the
  system libraries and frameworks it needs; writing to the RAM disk;
  listening on 127.0.0.1 on specific ports; and no outbound network.
  Child processes inherit it. `sandbox-exec` is deprecated and SBPL is
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
  CUPS on 631, maybe the secrets server). So list ports explicitly; if
  router mode's child processes can't use fixed ports, run one
  `llama-server` at a time on one port, switched by `infer-ctl`.
* launchd plist keys: `UserName`/`GroupName`; `EnvironmentVariables`
  with `HOME` and `TMPDIR` on the RAM disk; `Umask` 077; and
  `HardResourceLimits` with `Core` 0, so a core dump (process memory,
  including the KV cache) can never be written.
* TCC adds a layer: a daemon with no privacy grants can't read protected
  folders (Documents, Desktop, ...).
* Maybe pf as a second network layer (`block out ... user _infer`), if
  macOS's pf honors `user`.
* Fallback, if `(deny default)` turns into an endless list of Metal
  allowances: allow by default but deny outbound network, writes
  outside the RAM disk, and reads of `/Users` and other sensitive
  paths. That's weaker, but still covers the goals that matter most.

### Keeping data off the SSD

* The model weights and KV cache are in wired memory, which can't be
  swapped (see "Test results"). Size things so macOS never needs swap.
* Swap is acceptable for confidentiality if it's encrypted and a reboot
  makes it unreadable. Apple's Platform Security guide (August 2026,
  "Role of Apple File System") says the VM volume "is unencrypted and is
  used by macOS for storing encrypted swap files", and
  `sysctl vm.swapusage` here shows `(encrypted)`. I couldn't find an
  authoritative source saying the key changes at each boot; I believe it
  does, since swap is never read back after a reboot. We still avoid
  swap, to avoid SSD writes. What could be swapped: the engine's
  ordinary CPU memory (requests, tokens, output) and the VMs' RAM.
* A small RAM disk owned by `_infer` (maybe 256 MB) holds logs, `$TMPDIR`,
  and anything else file-backed. A root LaunchDaemon creates it at boot,
  e.g., `diskutil erasevolume APFS INFER $(hdiutil attach -nomount
  ram://N)`, unless `/sbin/mount_tmpfs` exists and is simpler. Traps:
  * macOS ignores ownership on attached volumes by default, so run
    `diskutil enableOwnership`, then `chown _infer` and `chmod 700`;
  * Spotlight could copy log contents into its index on the SSD, so
    mount it `nobrowse` and run `mdutil -i off`; also exclude it from
    Time Machine;
  * fail closed: if the RAM disk wasn't created, `/Volumes/INFER` could
    be a plain directory on the SSD, so the engine's start script must
    verify it's a RAM-backed mount and refuse to start otherwise.
* Kill on sleep (lid-close sleep and hibernation): a small root daemon
  registers with IOKit's `IORegisterForSystemPower`. On
  `kIOMessageSystemWillSleep` it runs `launchctl bootout` on the engine,
  waits for it to exit, then calls `IOAllowPowerChange` (macOS waits up
  to about 30 seconds). On wake it runs `launchctl bootstrap`; with
  on-demand loading, nothing loads until a request arrives. Use
  `bootout`, not a plain kill, since `KeepAlive` would restart a killed
  engine mid-sleep. AppKit's sleep notification doesn't delay sleep, so
  it would race with the sleep image. Build it as a tiny C program with
  Apple's Command Line Tools installed only while building it (not
  Homebrew), or use sleepwatcher's prebuilt binary if it has one and
  runs its script before acknowledging sleep.
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
* Layout follows `--models-dir`: single-file models directly in it, each
  multi-file model (multi-shard, or with an `mmproj` file) in its own
  subdirectory.
* Current models: Qwen3.8-27B as Q8_0 (default) and UD-Q4_K_M, from
  unsloth, and Qwen3-0.6B Q4_0 from ggml-org for quick tests; all
  Apache-2.0.
* Safety against malicious models:
  * GGUF or safetensors only, never pickle formats (`.bin`, `.pt`,
    `.ckpt`), which run code on load;
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
  confine). Revisit MLX if I move to a mixture-of-experts model. If I
  ever need more than one engine (e.g., for images), put `llama-swap` on
  the tunneled port to map model names to backends.
* Image models (e.g., FLUX.2 dev, 19-27 GB quantized) need a separate
  engine: stable-diffusion.cpp (C++, GGUF, Metal) fits a small host best;
  mflux (MLX, Python) is the other option.
* No Internet for the secure VM (rejected: it needs Internet; nono's
  allowlist limits it instead).
* nono on the host (rejected: it needs Homebrew, and built-in Seatbelt
  is the same mechanism).
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

## Test results (2026-10-18)

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

## Remaining work

In order. Steps marked (sudo) need me, since the AI doesn't run sudo
here.

1. **Host sandbox** (the one remaining question that could change the
   design). Phase B1: a permissive profile that only blocks outbound
   network and writes outside a log directory, first checked by hand
   (a `curl` and a write must fail), then running the `_infer` server
   daemon. Phase B2: `(deny default)`, built up from
   `log stream --predicate 'sender == "Sandbox"'`, starting from nono's
   `--allow-gpu` rules and Chromium's GPU-process profile. Also check:
   * `has tensor = true` under the sandbox, since llama.cpp compiles a
     test kernel at startup and silently disables the tensor API if
     that fails, which would cost 2.6x on prefill;
   * whether router mode's child processes can use fixed ports;
   * whether pf honors `user` rules.
2. **RAM disk** (sudo): the boot-time LaunchDaemon, the traps above, and
   how it behaves under memory pressure (does it stay out of swap?).
3. **Engine daemon** (sudo): the launchd plist, the fail-closed start
   script, router mode with a preset file and the settings above,
   `infer-ctl`, and its sudoers rule.
4. **Sleep watcher** (sudo): check whether every lid close writes RAM to
   `/private/var/vm/sleepimage` (`pmset -g`, the file's modification
   time). Verify the watcher can delay sleep long enough, that freed
   pages aren't in the sleep image (I believe macOS writes only in-use
   pages), and that forced sleep at critically low battery still sends
   the notification.
5. **Tunnels and `infer-access`**, with the new `config.sh` settings.
6. **Secure VM**: create it with LUKS, run `vm-setup.sh`, set up goose
   and pi against the engine, write the nono allowlist (which hosts do
   they need?), and refuse inbound connections from other VMs.
7. **End-to-end checks**: nothing from `_infer` reaches the SSD (e.g.,
   `fs_usage` during a session), swap stays at 0 after a heavy session,
   and usability in real use, including MTP speculative decoding.
8. **File Sharing**: turn it off, or at least guest access (my action).
9. **Documentation**: move the lasting parts into `architecture.md` and
   `README.md`.
