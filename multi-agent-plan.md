# Multi-agent plan: serving several agents from one local model

Status (2026-11-01): ideas to review; nothing here is implemented. The
engine runs Qwen3.8-27B with `--parallel 1 --cache-ram 0` (see
`local-ai-plan.md` and `initial-models.yaml`).

## The problem

I want one busy main agent, often using most of the 262K context (and
sometimes compacting), plus a few sub-agents with small contexts.

With `--parallel 1`, llama-server keeps one conversation's processed
context (its KV cache and Qwen3.8's recurrent state). When another
agent's request arrives, it discards that conversation, so when the
first agent's turn comes back, llama-server reprocesses its whole
context. At 40-50K tokens that takes minutes; near 262K, much longer.

## Options

### More slots, sharing one pool (`--parallel N --kv-unified`)

Each slot keeps its own conversation between turns. With `--kv-unified`,
all slots share one pool of `--ctx-size` tokens, and each conversation
takes space only as it grows; without it, each slot gets a fixed
`--ctx-size / N`. So one big conversation plus small ones fits, if the
pool is big enough: e.g., `--parallel 3 --kv-unified --ctx-size 393216`
(262K for the main agent, about 128K shared by sub-agents).

* Pro: no reprocessing when agents take turns, as long as each keeps its
  slot. Requests can also run at once.
* Con: memory for the bigger pool. I estimate the KV cache for 262K at
  about 10 GB, since most of Qwen3.8's layers (Gated DeltaNet) keep
  none, so about 5 GB more for 128K. Check the real size in
  llama-server's load log (the `llama_kv_cache` line, in MiB) first.
* Con: with a unified pool, I believe one slot could grow past 262K,
  beyond what the model was trained on. pi's `contextWindow` (from
  `capabilities.context`, 262144) makes pi compact first; llama-server's
  newer `--kv-unified-per-slot N` would enforce a per-slot limit too.
* Con: I haven't checked that MTP speculative decoding works as well
  with several slots in our build.
* Privacy: nothing new; it's the same, already-wired KV cache memory.
* If memory is short, `--cache-type-k q8_0 --cache-type-v q8_0` roughly
  halves the KV cache, at some cost in accuracy at long context.

### The prompt cache (`--cache-ram`): no, for now

It saves a slot's state in RAM when another conversation takes the
slot, and restores it later.

* It suits many short conversations, not ours: a saved conversation
  near 262K costs about as much as the KV cache itself.
* It's ordinary (swappable) memory, which is why we turned it off; see
  `local-ai-plan.md`, "Keeping data off the SSD".
* It has an open bug that mixes conversations: [llama.cpp #27148][bug]
  (`--cache-ram` with `--cache-idle-slots`, the defaults) can restore an
  unrelated, finished conversation into a new request's slot, and the
  model continues that one instead, with no sign to the client. It's
  been reproduced with strictly sequential requests and on Metal, on
  builds up to at least b11146; we run b11669. The proposed fix,
  [PR #27624][fix], was still open on 2026-11-01. The reported
  workaround is `--cache-ram 0`, which we have. That's a correctness
  and a privacy problem (one agent's conversation in another's reply),
  so keep `--cache-ram 0` until it's fixed.
* `--slot-save-path` (saving slots to disk) is out: it breaks the
  engine's no-writes design.

## The catch: agents taking each other's slots

For each request, llama-server takes an idle slot whose cached prompt
matches the new prompt's beginning well enough
(`--slot-prompt-similarity`, default 0.10), not the best match. A
[benchmark of several agents][bench] found that, since their prompts
share a scaffold, about 10% of 1,456 slot choices discarded another
agent's context (e.g., `f_sim_best = 0.415 (> 0.100 thold), f_keep =
0.024`).

For us it could be worse: a new pi sub-agent's first prompt is mostly
pi's system prompt and tools, so it can match the main agent's slot
strongly, and that slot is idle exactly when the main agent waits for
its sub-agent. Each sub-agent could then cost the main agent a full
reprocess.

Raising `--slot-prompt-similarity` (e.g., 0.9) helps less than it
seems: a sub-agent whose prompt gains a big tool result could miss its
own slot, and the fallback takes the least recently used slot, which
could be the waiting main agent's.

## Pinning: the fix I'd try

Send `id_slot` with each request, so each agent always uses its own
slot. llama-swap can add it per model name, with `setParamsByID`, the
way it already makes the `:instruct` variant; no new code:

```yaml
    cmd: ${llama-server} ... --parallel 3 --kv-unified --ctx-size 393216 ...
    filters:
      setParamsByID:
        "${MODEL_ID}":            # the main agent: always slot 0
          temperature?: 1.0
          ...
          id_slot: 0
        "${MODEL_ID}:sub":        # sub-agents: slot 1, same sampling
          temperature?: 1.0
          ...
          id_slot: 1
        "${MODEL_ID}:instruct":   # no thinking: slot 2
          ...
          id_slot: 2
```

`id_slot` has no `?`, so llama-swap always sets it and a client can't
override it. pi already lists variants (`includeAliasesInList`), so
`qwen3.8-27b:sub` would show up in nopi with no other change.

Sub-agents then have to use the `:sub` name. pi has no sub-agents of
its own; its example extension (`examples/extensions/subagent` in pi's
package) runs each one as a separate `pi` process, with the agent
definition's `model:`, or else the parent's model, which would put it
on slot 0. So either:

* set `model: qwen3.8-27b:sub` (perhaps `mac-local/qwen3.8-27b:sub`;
  unchecked) once in each agent definition (`scout.md`, `worker.md`,
  ...); or
* change the extension's fallback (near `index.ts:300`) to the parent's
  model plus `:sub`: fully automatic, but then we maintain our own copy.

Which applies depends on which sub-agent extension I use.

Caveats to check:

* Does llama-server honor `id_slot` on `/v1/chat/completions`? Its
  README documents it for `/completion`. Its log says `selected slot by
  id` when it does.
* Requests pinned to a busy slot wait, so parallel sub-agents on `:sub`
  take turns. If that's common, add `:sub2` on slot 3, and send
  different agents to different variants.
* Two main pi sessions at once share slot 0 and evict each other, as
  now.

## The especially-private VM

Nothing new needed: every `infer-access.sh` mode change restarts the
engine, which discards every slot (and would discard a prompt cache),
and the sleep hook stops llama-server too. Modes are exclusive for this
reason (see `local-ai-plan.md`).

## How to tell whether it worked

Use `./infer-doctor.sh`'s request table on the Mac (or `journalctl
--user -u infer-logs@upstream` in a VM). When the main agent's turn
comes after a sub-agent's, its prompt count should be small (hundreds
of tokens), not its whole context. Compare speeds only at similar
context lengths, on AC power.

## References

* [llama.cpp server README][readme] (`--parallel`, `--kv-unified`,
  `--kv-unified-per-slot`, `--slot-prompt-similarity`, `--cache-ram`,
  `--cache-idle-slots`, `id_slot`)
* [Benchmark issue: pin agent requests to llama.cpp slots][bench]
* [llama.cpp #27148: the RAM prompt cache restores an unrelated
  conversation][bug], and [PR #27624][fix]
* [Two slots on a shared unified pool (a nix-config pull request)][nix]
* [Tutorial: KV cache reuse with llama-server][reuse]

[readme]: https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md
[bench]: https://github.com/Nasus20202/MastersThesis/issues/96
[bug]: https://github.com/ggml-org/llama.cpp/issues/27148
[fix]: https://github.com/ggml-org/llama.cpp/pull/27624
[nix]: https://github.com/Emmberkat/nix-config/pull/798
[reuse]: https://github.com/ggml-org/llama.cpp/discussions/13606
