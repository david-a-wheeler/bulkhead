# Model candidates info

This file identifies some local models worth considering for the Mac's
engine, mainly for writing code and doing math in English, with their
trade-offs. This isn't the list of models a host serves; that's
`models.local.yaml` (see `initial-models.yaml` and `manage-models.sh`).

This file is my personal set of notes, as edited by AI tools.
Nearly all information here is from others (and cited).
This file is *not* the result of my own experimental evaluation.
Do *not* treat this file as authoritative, it's simply my own notes.

The information here goes stale fast, so each entry says when we checked it.
Benchmarks are vendor-reported unless noted, and vendors use different
harnesses, so a gap of a few points doesn't mean much. A model also
needs llama.cpp support in a release we install, without a fork.

## Generalists and specialists

The engine serves two roles of model, and runs at most one of each at a time:

- A **generalist** can chat: it takes text (and, for some, images) and
  answers in text, so a harness such as pi can use it for coding and
  math. It's a llama-server model. You'd normally keep one loaded, since
  reloading it means reprocessing your conversation.
- A **specialist** does something a generalist can't, such as making
  images. It's typically an sd-server model, loads beside the
  generalist only when you ask for it, and unloads soon after.

So a generalist's memory is spent for as long as it's loaded, while a
specialist only needs to fit beside it briefly.

These are my categories, implemented by these tools. They follow from
two limits:

- **The programs that run the models.** llama.cpp (llama-server) reads
  text and, with a vision projector, images, but it only writes text;
  it can't make images. stable-diffusion.cpp (sd-server) only makes
  images (and video). It does run a language model, but only as a text
  encoder that turns your prompt into input for the image model; you
  can't chat with it. Most models do only one of these jobs anyway, so
  even a program that did both wouldn't make, e.g., FLUX.2-klein-4B
  chat. A few "unified" models (e.g., HiDream-O1-Image) handle both
  text and images, but neither program uses them for both.
- **Memory.** My computer has limited RAM, so keeping one generalist
  loaded and loading a specialist beside it only briefly keeps both
  within budget. To make room for a big specialist, you can unload the
  generalist (llama-swap's `POST /api/models/unload/MODEL`), or request
  a small one, at the cost of its KV cache. Nothing then stops a chat
  request from loading the generalist again beside it, so the two
  together could exceed what Metal can use.

## Sizes and quantization

The memory budget for weights plus KV cache (the model's memory of the
conversation so far) is about 85-90 GB (see `local-ai-plan.md`'s memory
budget). Released weights are usually 16 bits per parameter, so a 27B
model is about 54 GB and a 118B one about 236 GB. A quantized GGUF
stores weights in fewer bits, trading some quality for memory and
speed. Its size is roughly the parameter count times the bits per
weight, divided by 8. The names we use here:

- **Q8_0**: about 8.5 bits per weight; nearly lossless.
- **Q6_K, Q5_K_M**: about 6.6 and 5.7 bits; very small losses.
- **Q4_K_M, IQ4_XS**: about 4.3-4.8 bits; a small but real loss. This
  is the usual choice when a model's too big for Q8_0.
- **Q3 and Q2 quants (including IQ2 and IQ3)**: about 2-3.5 bits; a
  clear loss, worse for smaller models.

"K" quants mix precisions within a tensor, and "IQ" quants use an
importance matrix (measured on sample text) to keep the weights that
matter most more precise. Uploaders add variants: e.g., unsloth's "UD"
quants vary the precision by layer, and bartowski's "_L" quants keep
the embedding and output weights at Q8_0. Sizes here are for the quant
we'd use.

Each entry also estimates the **RAM** a model uses once loaded: its
weights, plus, for a generalist, its KV cache at the context size given,
or, for a specialist, its working memory for a 1024x1024 image. Unless
an entry says it was measured, these are our estimates from the model's
published sizes and settings, so they could be off by a few GB.

A model is **dense** or a **mixture of experts (MoE)**. A dense model
uses every weight for every token. An MoE model has many "experts" and
uses only a few for each token: e.g., Laguna S 2.1 has 118B parameters
in total but only about 8B active. All the weights must still fit in memory,
but generating a token reads only the active ones, and memory bandwidth
limits generation speed. So an MoE model needs memory for its total
size but generates at about the speed of a dense model with its active size.

## Generalists

### Qwen3.8-27B

- Model card: [Qwen/Qwen3.8-27B][qwen38]
- Checked 2026-10-25. Apache 2.0. Dense, 27B, with a vision encoder.
  Context 262,144 tokens.
- Size: 27 GiB at Q8_0, plus a 0.9 GB vision projector. RAM: about
  43 GB at 262,144 tokens of context (measured; see
  `local-ai-plan.md`). Most of its layers (Gated DeltaNet) keep no KV
  cache, which keeps that small [qwen38].
- It's `initial-models.yaml`'s default generalist. Other candidates are
  measured against it.
- Pros: the strongest coding and math scores we've found among models
  that fit (Terminal-Bench 2.1 73.0, SWE-Bench Pro 61.7, LiveCodeBench
  v6 90.3 [qwen38]; math average 97.8 in [Aleph Alpha's
  table][kolibri]); reads images; mature llama.cpp support.
- Cons: a dense model reads all its weights for every token, so
  generation is slow: 18.4 tokens/s at Q8_0, 27.0 at UD-Q4_K_M
  (measured; see `local-ai-plan.md`).

### Laguna S 2.1 (poolside)

- Model card: [poolside/Laguna-S-2.1][laguna]; GGUFs:
  [poolside][laguna-gguf], [bartowski][laguna-bartowski],
  [unsloth][laguna-unsloth]
- Checked 2026-10-25. OpenMDW-1.1 (permissive). MoE, 118B total, about
  8B active. Context 256K by default, 1M with YaRN.
- Size: poolside's Q4_K_M is 68 GB, one file. Q5 quants are 84-88 GB,
  which leaves no room for anything else. RAM: about 75-83 GB at
  128K-256K tokens of context, since only 12 of its 48 layers keep the
  whole context (we assumed 128-wide attention heads). If prompt reuse
  needs `--swa-full` (below), the KV cache grows about four times, which
  wouldn't fit at 256K.
- The 68 GB figure is not poolside's file (checked 2026-10-25 by parsing
  the GGUF headers). [Poolside's `Q4_K_M` is 96.03 GB][laguna-gguf]: most
  of its routed experts are Q5_K, about 19B parameters of experts are
  BF16, and its attention, shared experts, and output are Q8_K, so it
  averages about 8.2 bits per weight. It doesn't fit our 85-90 GB budget
  even at a 32K context. The 68 GB size matches [ggml-org's
  `Q4_K_M`][laguna-ggml-org], 67.66 GB, a standard 4.5-bit quant, which
  fits with about 13 GB of KV cache at 262,144 tokens (about 80 GB
  total); poolside's `Q8_0`, 128.75 GB, doesn't fit at all.
- Pros: we'd expect generation about 3-4 times faster than
  Qwen3.8-27B at Q8_0, since only about 8B parameters are read per
  token (an estimate; MLX measured 65-78 tokens/s on an M5 Max
  [laguna-mlx]); trained for agentic coding, and one reviewer saw no
  malformed tool calls [peaster]; small KV cache per token.
- Cons: coding scores about even with Qwen3.8-27B, not better
  (Terminal-Bench 2.1 70.2, SWE-Bench Pro 59.4 [laguna]), and a 4-bit
  quant loses a little more; text only; about 25-30 GB more memory.
  llama.cpp support is new: it arrived in [PR #25165][llama-25165]
  (merged 2026-07-22, in b10087), which tested CPUs, not Metal (Apple GPUs).
  Reports of reasoning that doesn't start or never ends
  [laguna-reasoning] [peaster], and of prompt reuse needing
  `--swa-full`, which multiplies its KV cache by about four
  [llama-25165]. One reviewer saw more made-up facts than from Qwen [peaster].
- Use a GGUF made after 2026-07-24: poolside fixed its RoPE metadata
  and chat template after release [peaster].
- Adding it (2026-10-25, not yet tried on the Mac): on the host,
  `./manage-models.sh add laguna-s-2.1 https://huggingface.co/ggml-org/Laguna-S-2.1-GGUF --no-mmproj`
  (it's text only, so no vision projector; the quant repo publishes no
  license of its own, so `add` records `NOASSERTION` - the base model is
  OpenMDW-1.1). Then edit the entry it writes, the way the Qwen entries
  here are edited:
  - `--jinja`, so llama-server uses the chat template baked into the
    GGUF; it does the tool-calling and the reasoning.
  - An explicit `--ctx-size 262144` (and `capabilities.context:
    262144`): 1M would need about 49 GB more KV cache and doesn't fit
    while VMs run.
  - The template defaults to `enable_thinking: true`, and the card
    recommends keeping each turn's thinking in the history. Whether
    llama-server's `--reasoning-budget` works with this template is
    untested, and there are reports of reasoning that doesn't start or
    never ends (above). If so, either let `metadata.max_tokens` bound
    thinking, or add a second entry (a llama-swap alias, like
    qwen3.8-27b's `:instruct`) with
    `chat_template_kwargs: {enable_thinking: false}` for direct answers.
  - The GGUF embeds its sampling defaults (temperature 1.0, top_p 1.0,
    top_k 20, min_p 0.05; read from the file's header), and the card
    recommends none, so no `filters` block is needed at first.
  - Leave it a second generalist (no `metadata.default`), so
    llama-swap swaps it in and out of Qwen3.8-27B on demand.
  - The card offers a DFlash draft model (2.23 GB GGUF) for
    speculative decoding, but it says that's on Poolside's llama.cpp
    fork; upstream support is unverified, so treat it as a later
    experiment, not part of the entry.
  The resulting entry should look like this, with the `# file:` line's
  SHA-256 filled in by `add`:
  ```yaml
    laguna-s-2.1:
      # file: Laguna-S-2.1-Q4_K_M.gguf <sha256> NOASSERTION https://huggingface.co/ggml-org/Laguna-S-2.1-GGUF/resolve/main/Laguna-S-2.1-Q4_K_M.gguf
      name: "Laguna S 2.1 Q4_K_M"
      cmd: ${llama-server} --model ${models-dir}/Laguna-S-2.1-Q4_K_M.gguf --ctx-size 262144 --jinja
      proxy: ${proxy}
      capabilities:
        in: [text]
        out: [text]
        context: 262144
      metadata:
        max_tokens: 65536
  ```
- Revisit if: speed starts to matter.

### Qwen3.6-35B-A3B

- Model card: [Qwen/Qwen3.6-35B-A3B][qwen36]
- Checked 2026-10-25. Apache 2.0. MoE, 35B total, 3B active, with a
  vision encoder. Context 262,144 tokens.
- Size: roughly 37 GB at Q8_0 (our estimate from its parameter count).
  RAM: about 42-45 GB at 262,144 tokens, if, like Qwen3.8, only some
  of its layers keep a KV cache.
- Pros: very fast for its scores, since only 3B parameters are active;
  reads images; small enough to leave lots of room; SWE-bench Verified
  73.4 [qwen36], about even with Qwen3.8-27B's 72.6 in
  [Aleph Alpha's table][kolibri].
- Cons: much weaker at multi-step terminal work (Terminal-Bench 2.0
  51.5 [qwen36], against Qwen3.8-27B's 73.0 on 2.1) and on
  LiveCodeBench v6 (80.4); superseded by Qwen3.8.
- Revisit if: we want a small fast generalist that still reads images.

### Kolibri-1 (Aleph Alpha)

- Model card: [aleph-alpha/Kolibri-1][kolibri]
- Checked 2026-10-25. Apache 2.0 (weights and configuration only).
  MoE, 78B total, 3.46B active. Text only. Context 262,144 tokens
  recommended, 1M validated. Strongest in German and English.
- Size: Q4_K_M about 48-50 GB [ssdnodes-1] [ssdnodes-2]. RAM: about
  52-56 GB at 262,144 tokens; a fifth of its layers keep the whole
  context.
- Pros: fast (3.46B active); strong at math (average 96.5 [kolibri]);
  trained with over 20% German, if you need German.
- Cons: by its own table it trails Qwen3.8-27B at everything we care
  about (SWE-bench Verified 66.4, LiveCodeBench v6 85.9, Terminal-Bench
  2.1 27.7 [kolibri]). Aleph Alpha documents only vLLM with its own
  plugin; reports disagree on whether stock llama.cpp runs it yet
  [ssdnodes-1] [ssdnodes-2].
- Revisit if: you want German, and llama.cpp supports it.

### Inkling-Small (Thinking Machines)

- Model card: [Inkling-Small][inkling]; weights:
  `thinkingmachines/Inkling-Small` on Hugging Face
- Checked 2026-10-25. Apache 2.0. MoE, 276B total, 12B active. Reads
  text, images, and audio. Context up to 1M tokens.
- Size: it would fit only at about 2 bits per weight, about 70 GB.
  RAM: about 75-85 GB with a modest context, i.e., the whole budget.
- Pros: the highest claimed coding score here (SWE-bench Verified 80.2
  [inkling]); reads images.
- Cons: 2-bit quants lose a lot of quality; an independent rerun of
  Terminal-Bench 2.1 got 55%, not the vendor's 64.7% [techjack]; weak
  factuality (SimpleQA Verified 20.6 [inkling]). Its card lists no
  llama.cpp support.
- Revisit if: llama.cpp supports it and independent evaluations hold
  up at a quant that fits.

### gpt-oss-120b (OpenAI)

- Model card: [openai/gpt-oss-120b][gpt-oss]
- Checked 2026-10-25. Apache 2.0. MoE, 117B total, 5.1B active, MXFP4
  weights. Text only. Released August 2025.
- Size: about 63-66 GB [pinggy]. RAM: about 68-71 GB at its 131,072
  tokens of context; half its layers use a short sliding window, so its
  KV cache is about 5 GB.
- Pros: mature llama.cpp support; fast (5.1B active); strong on
  science questions (GPQA Diamond 80.8 [gpt-oss]).
- Cons: weak at agentic coding (SWE-Bench Pro 16.2 [gpt-oss]); older
  than everything else here.
- Revisit if: unlikely for code.

### Qwen3-0.6B

- Model card: [Qwen/Qwen3-0.6B][qwen3-06]; GGUF:
  [ggml-org/Qwen3-0.6B-GGUF][qwen3-06-gguf]
- Checked 2026-10-25. Apache 2.0. Dense, 0.6B (0.44B without
  embeddings). Text only. Context 32,768 tokens. Thinking can be turned
  on or off.
- Size: under 0.5 GB at Q4_0. RAM: about 4 GB at 32,768 tokens of
  context, mostly KV cache: every layer keeps the whole context.
- Not a coding or math model: it's for testing the engine and the
  tools around it. It loads in moments, it's fast (about 480 tokens/s
  generation, measured; see `local-ai-plan.md`), and it still answers
  simple questions and makes tool calls, so a test checks something
  real.
- Cons: too small for real work; its card warns of endless repetition,
  which a higher `presence_penalty` reduces [qwen3-06].

## Specialists

These are image models: they make images from a prompt, and most can
also edit images you give them (which `my-gen-image` uses). Each needs
stable-diffusion.cpp support (it supports dozens [sdcpp]), and each is
an image model plus a text encoder (a small language model) and a VAE,
so sizes below include all three.

A specialist loads beside the generalist, so it should fit in what the
generalist leaves: about 42-47 GB beside Qwen3.8-27B at Q8_0. Their
RAM estimates add a GB or two of working memory to the file sizes.

Rankings here are Elo scores from Artificial Analysis's blind
comparisons of text-to-image [aa-t2i] and editing [aa-edit], where
FLUX.2-dev is fixed at 1000. Nearby scores overlap, so a gap of 10-20
points doesn't mean much.

Licenses vary more than for generalists. Only three here use an open
source license (FLUX.2-klein-4B, Z-Image-Turbo, and HiDream-O1-Image);
the rest are non-commercial or limited by revenue, which is fine for
personal use but not for work. Some repositories are gated: they need a
Hugging Face login, and `manage-models.sh` doesn't log in, so you'd
download those by hand.

### FLUX.2-klein-4B (Black Forest Labs)

- Model card: [black-forest-labs/FLUX.2-klein-4B][klein4b]; GGUF:
  [leejet/FLUX.2-klein-4B-GGUF][klein4b-gguf]
- Checked 2026-10-25. Apache 2.0. 4B, with a Qwen3-4B text encoder.
  4 steps. Released January 2026.
- Size: about 9 GB at Q8_0 (see `local-ai-plan.md`). RAM: about
  10-12 GB.
- It's `initial-models.yaml`'s image model.
- Pros: open source license; small and fast; edits with one or several
  reference images; its own (ungated) VAE works in stable-diffusion.cpp
  (tested; see `local-ai-plan.md`).
- Cons: the lowest-ranked here (text-to-image 837, editing 938
  [aa-t2i] [aa-edit]).

### Qwen-Image-2.1 (Alibaba)

- Model card: [Qwen/Qwen-Image-2.1][qwen-image]; GGUF:
  [leejet/Qwen-Image-2.1-GGUF][qwen-image-gguf]; usage:
  [stable-diffusion.cpp's docs][sdcpp-qwen-image]
- Checked 2026-10-25. Qwen Research License (not open source; for
  research and non-commercial use). 7B, with a Qwen3-VL-8B text
  encoder. A Turbo setting uses 8 steps. Released September 2026.
- Size: about 18 GB at Q8_0 (see `local-ai-plan.md`). RAM: about
  20-24 GB; it also caches the prompt's encoding, about 2 GB for a long
  prompt [sdcpp-qwen-image].
- Pros: among the top open-weight models at both (text-to-image 1042,
  editing 1081 [aa-t2i] [aa-edit]); edits with up to 10 reference
  images, and with circles, painted notes, or masks [qwen-image].
- Cons: restrictive license; needs its own VAE (earlier Qwen-Image
  VAEs don't work) [sdcpp-qwen-image].

### FLUX.3 Image Klein (Black Forest Labs)

- Model card: [black-forest-labs/flux-3-image-klein][flux3]; GGUF:
  [leejet/flux-3-image-klein-GGUF][flux3-gguf]; usage:
  [stable-diffusion.cpp's docs][sdcpp-flux3]
- Checked 2026-10-25. FLUX Kommunity License: non-commercial use, plus
  commercial use of images by those with under US$5M a year in revenue
  [flux3]. Gated. 5.6B, with a Qwen3-VL-4B text encoder. 16 steps.
  Released October 2026.
- Size: about 11 GB at Q8_0 (see `local-ai-plan.md`). RAM: about
  12-14 GB.
- Pros: tied for the top open-weight text-to-image score (1043), and
  near the top at editing (1072) [aa-t2i] [aa-edit]; up to 10
  reference images, and bounding boxes to place things [flux3].
- Cons: not open source; gated; its card says to always expand prompts
  first (with a "prompt upsampler"), since short prompts give generic
  images [flux3]; very new, and early hands-on reviews are mixed (one
  edit grafted a trumpet bell onto a saxophone instead of swapping
  them) [flux3-review].
- Revisit if: independent reviews hold up.

### Fibo 2.0 (Bria)

- Model card: [briaai/Fibo-2.0-dev][fibo]; usage:
  [stable-diffusion.cpp's docs][sdcpp-fibo]
- Checked 2026-10-25. CC BY-NC 4.0 (non-commercial). 8B, with a
  Qwen3-VL-4B text encoder. A separate Edit Turbo model edits in 4
  steps. Released October 2026.
- Size: roughly 14 GB at 8 bits (our estimate from its parameter
  counts). RAM: about 15-17 GB.
- Pros: the top open-weight editing score (1088), and tied at the top
  for text-to-image (1039) [aa-t2i] [aa-edit]; Bria says it's trained
  only on licensed images [fibo].
- Cons: non-commercial; stable-diffusion.cpp's docs use FLUX.2-dev's
  VAE, which is gated and under FLUX.2-dev's non-commercial license
  [sdcpp-fibo]; no GGUF from leejet yet (8-bit safetensors instead).

### Ideogram 4 (Ideogram)

- Model card: [ideogram-ai/ideogram-4-fp8][ideogram]
- Checked 2026-10-25. Ideogram 4 Non-Commercial license. Gated. 9.3B,
  with a Qwen3-VL-8B text encoder. Released June 2026.
- Size: roughly 24 GB: it has a second, "unconditional" transformer
  [sdcpp-ideogram], so two 9.3B transformers in FP8 (if they're the
  same size), plus its text encoder at Q4_K_M (our estimate). RAM:
  about 25-28 GB.
- Pros: Ideogram claims the best text rendering (lettering in images)
  of any open-weight model [ideogram]; text-to-image 1026 with its
  quality preset [aa-t2i].
- Cons: non-commercial; gated; text-to-image only, as far as its card
  says; uses FLUX.2-dev's gated VAE in stable-diffusion.cpp
  [sdcpp-ideogram].

### HiDream-O1-Image (HiDream)

- Model card: [HiDream-ai/HiDream-O1-Image-Dev-2604][hidream]
- Checked 2026-10-25. MIT. 9B, a single model with no separate text
  encoder (as far as its card says). The full model uses 50 steps, and
  the Dev version 28. Released May 2026.
- Size: roughly 10 GB at 8 bits (our estimate). RAM: about 12-14 GB.
- Pros: open source license; the full model ranks well above
  FLUX.2-klein-4B (text-to-image 975 [aa-t2i]).
- Cons: slow (28-50 steps, against 4-16 for the distilled models
  here); the Dev version ranks below FLUX.2-klein-4B (text-to-image 810
  [aa-t2i]), and the leaderboards don't list the newer Dev-2604; weak
  at editing (954 for the full model, 880 for Dev [aa-edit]), and its
  project recommends the full model for editing; stable-diffusion.cpp
  documents only text-to-image for it [sdcpp-hidream].
- Revisit if: you want better images under an open source license.

### Z-Image-Turbo (Alibaba Tongyi)

- Model card: [Tongyi-MAI/Z-Image-Turbo][z-image]; GGUF:
  [leejet/Z-Image-Turbo-GGUF][z-image-gguf]; usage:
  [stable-diffusion.cpp's docs][sdcpp-z-image]
- Checked 2026-10-25. Apache 2.0. 6B, with a Qwen3-4B text encoder. 8
  steps. Released late 2025.
- Size: roughly 11 GB at Q8_0 (our estimate). RAM: about 12-14 GB.
- Pros: open source license; fast; better ranked than FLUX.2-klein-4B
  (text-to-image 936 [aa-t2i]); uses FLUX.1-schnell's ungated,
  Apache-licensed VAE [sdcpp-z-image].
- Cons: no editing; the Z-Image-Edit model is "to be released"
  [z-image].

### FLUX.2-dev and FLUX.2-klein-9B (Black Forest Labs)

- Model cards: [black-forest-labs/FLUX.2-dev][flux2-dev],
  [black-forest-labs/FLUX.2-klein-9B][klein9b]
- Checked 2026-10-25. Both under the FLUX non-commercial license, and
  gated. FLUX.2-dev is 32B with a large text encoder; klein-9B is 9B,
  with a Qwen3-8B text encoder, and uses 4 steps [klein9b].
- Size: FLUX.2-dev is about 60 GB at Q8_0, or 35 GB at 4 bits (see
  `local-ai-plan.md`), so it doesn't fit beside Qwen3.8-27B at 8 bits.
  klein-9B is roughly 18 GB at Q8_0 (our estimate). RAM: about
  62-65 GB for FLUX.2-dev at Q8_0 (37-40 GB at 4 bits), and about
  19-21 GB for klein-9B.
- Pros: FLUX.2-dev was the strongest open-weight model until recently
  (1000 at both, the anchor); klein-9B edits well for its size (1015
  [aa-edit]).
- Cons: non-commercial and gated; newer models above match or beat
  them at a fraction of FLUX.2-dev's size.

### Stable Diffusion 3.5 (Stability AI)

- Model card: [stabilityai/stable-diffusion-3.5-large][sd35]; usage:
  [stable-diffusion.cpp's docs][sdcpp-sd3]
- Checked 2026-10-25. Stability AI Community License: free for
  non-commercial use, and for commercial use by those with under US$1M
  a year in revenue [sd35]. Gated. Large is 8B (Large Turbo is a
  faster version of it; Medium is 2.5B), with three text encoders:
  CLIP-L, CLIP-G, and T5-XXL (about 4.7B). About 28 steps for Large.
  Released October 2024; a guide updated 2026-10-23 still calls it
  Stability AI's newest [krea-sd], and we found no successor.
- Size: roughly 20 GB for Large at 8 bits with T5-XXL at 16 bits (our
  estimate). RAM: about 21-23 GB.
- Pros: well known, with many fine-tunes and tools built for it.
- Cons: not open source; gated; text-to-image only, as far as
  stable-diffusion.cpp's docs say [sdcpp-sd3]; old, it is two years older than
  most models here, and not on the current leaderboards at all
  [aa-t2i] [aa-edit].

## References

[qwen38]: https://huggingface.co/Qwen/Qwen3.8-27B "Qwen3.8-27B model card"
[laguna]: https://huggingface.co/poolside/Laguna-S-2.1 "Laguna S 2.1 model card"
[laguna-gguf]: https://huggingface.co/poolside/Laguna-S-2.1-GGUF "poolside's Laguna S 2.1 GGUFs"
[laguna-ggml-org]: https://huggingface.co/ggml-org/Laguna-S-2.1-GGUF "ggml-org's Laguna S 2.1 GGUFs"
[laguna-bartowski]: https://huggingface.co/bartowski/Laguna-S-2.1-GGUF "bartowski's Laguna S 2.1 GGUFs"
[laguna-unsloth]: https://huggingface.co/unsloth/Laguna-S-2.1-GGUF "unsloth's Laguna S 2.1 GGUFs"
[laguna-reasoning]: https://huggingface.co/unsloth/Laguna-S-2.1-GGUF/discussions/6 "unsloth discussion: reasoning does not work"
[laguna-mlx]: https://huggingface.co/jacklarmer/laguna-s-2.1-mlx-optimized "Laguna S 2.1 MLX speeds on M5 Max"
[llama-25165]: https://github.com/ggml-org/llama.cpp/pull/25165 "llama.cpp PR #25165: Laguna support"
[peaster]: https://peaster.io/articles/local-LLMs/laguna-s-2-1-on-dual-3090 "Laguna S 2.1: Don't Let It Think"
[qwen36]: https://huggingface.co/Qwen/Qwen3.6-35B-A3B "Qwen3.6-35B-A3B model card"
[kolibri]: https://huggingface.co/aleph-alpha/Kolibri-1 "Kolibri-1 model card, with its comparison table"
[ssdnodes-1]: https://www.ssdnodes.com/learn/lang/id/what-it-takes-to-self-host-kolibri-1 "What it takes to self-host Kolibri-1"
[ssdnodes-2]: https://www.ssdnodes.com/learn/lang/de/run-kolibri-1-on-a-vps "Run Kolibri-1 on a VPS"
[inkling]: https://thinkingmachines.ai/model-card/inkling-small/ "Inkling-Small model card"
[techjack]: https://techjacksolutions.com/ai-brief/inkling-small-swebbench-coding-benchmark-factuality-tradeoff/ "Inkling-Small benchmark and factuality trade-off"
[gpt-oss]: https://huggingface.co/openai/gpt-oss-120b "gpt-oss-120b model card"
[pinggy]: https://pinggy.io/blog/top_5_local_llm_tools_and_models/ "Best local LLM tools and models: what fits in 128GB"
[qwen3-06]: https://huggingface.co/Qwen/Qwen3-0.6B "Qwen3-0.6B model card"
[qwen3-06-gguf]: https://huggingface.co/ggml-org/Qwen3-0.6B-GGUF "ggml-org's Qwen3-0.6B GGUFs"
[sdcpp]: https://github.com/leejet/stable-diffusion.cpp "stable-diffusion.cpp, with its list of supported models"
[aa-t2i]: https://artificialanalysis.ai/image/leaderboard/text-to-image?open-weights=true "Artificial Analysis text-to-image leaderboard (AA-Image-T2I v2.1), open-weight models"
[aa-edit]: https://artificialanalysis.ai/image/leaderboard/editing?open-weights=true "Artificial Analysis image editing leaderboard (AA-Image-Editing v2.1), open-weight models"
[klein4b]: https://huggingface.co/black-forest-labs/FLUX.2-klein-4B "FLUX.2-klein-4B model card"
[klein4b-gguf]: https://huggingface.co/leejet/FLUX.2-klein-4B-GGUF "leejet's FLUX.2-klein-4B GGUFs"
[qwen-image]: https://huggingface.co/Qwen/Qwen-Image-2.1 "Qwen-Image-2.1 model card"
[qwen-image-gguf]: https://huggingface.co/leejet/Qwen-Image-2.1-GGUF "leejet's Qwen-Image-2.1 GGUFs"
[sdcpp-qwen-image]: https://github.com/leejet/stable-diffusion.cpp/blob/master/docs/qwen_image_2.1.md "stable-diffusion.cpp: Qwen Image 2.1"
[flux3]: https://huggingface.co/black-forest-labs/flux-3-image-klein "FLUX.3 Image Klein model card"
[flux3-gguf]: https://huggingface.co/leejet/flux-3-image-klein-GGUF "leejet's FLUX.3 Image Klein GGUFs"
[sdcpp-flux3]: https://github.com/leejet/stable-diffusion.cpp/blob/master/docs/flux3.md "stable-diffusion.cpp: FLUX.3 Image Klein"
[flux3-review]: https://www.creativeainews.com/articles/flux-3-image-klein-open-weights-license-test-2026/ "FLUX 3 Image Klein: open weights, license, and a test (2026-10-15)"
[fibo]: https://huggingface.co/briaai/Fibo-2.0-dev "Fibo 2.0 Dev model card"
[sdcpp-fibo]: https://github.com/leejet/stable-diffusion.cpp/blob/master/docs/fibo2.md "stable-diffusion.cpp: Fibo 2.0"
[ideogram]: https://huggingface.co/ideogram-ai/ideogram-4-fp8 "Ideogram 4 model card"
[sdcpp-ideogram]: https://github.com/leejet/stable-diffusion.cpp/blob/master/docs/ideogram4.md "stable-diffusion.cpp: Ideogram4"
[hidream]: https://huggingface.co/HiDream-ai/HiDream-O1-Image-Dev-2604 "HiDream-O1-Image-Dev-2604 model card"
[sdcpp-hidream]: https://github.com/leejet/stable-diffusion.cpp/blob/master/docs/hidream_o1_image.md "stable-diffusion.cpp: HiDream-O1-Image"
[z-image]: https://huggingface.co/Tongyi-MAI/Z-Image-Turbo "Z-Image-Turbo model card"
[z-image-gguf]: https://huggingface.co/leejet/Z-Image-Turbo-GGUF "leejet's Z-Image-Turbo GGUFs"
[sdcpp-z-image]: https://github.com/leejet/stable-diffusion.cpp/blob/master/docs/z_image.md "stable-diffusion.cpp: Z-Image"
[flux2-dev]: https://huggingface.co/black-forest-labs/FLUX.2-dev "FLUX.2-dev model card"
[klein9b]: https://huggingface.co/black-forest-labs/FLUX.2-klein-9B "FLUX.2-klein-9B model card"
[sd35]: https://huggingface.co/stabilityai/stable-diffusion-3.5-large "Stable Diffusion 3.5 Large model card"
[sdcpp-sd3]: https://github.com/leejet/stable-diffusion.cpp/blob/master/docs/sd3.md "stable-diffusion.cpp: SD3 and SD3.5"
[krea-sd]: https://www.krea.ai/blog/is-stable-diffusion-free-where-to-get-it-and-what-it-costs-in-2026 "Is Stable Diffusion free in 2026?"
