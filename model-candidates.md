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

These are my categories, implemented by these tools. My computer has limited RAM;
these categories simplify loading things.

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
- It's `initial-models.yaml`'s default generalist, at Q8_0 (about
  43 GB loaded, with its KV cache). Other candidates are measured
  against it.
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
  which leaves no room for anything else.
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
- Revisit if: speed starts to matter.

### Qwen3.6-35B-A3B

- Model card: [Qwen/Qwen3.6-35B-A3B][qwen36]
- Checked 2026-10-25. Apache 2.0. MoE, 35B total, 3B active, with a
  vision encoder. Context 262,144 tokens.
- Size: roughly 37 GB at Q8_0 (our estimate from its parameter count).
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
- Size: Q4_K_M about 48-50 GB [ssdnodes-1] [ssdnodes-2].
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
- Size: it would fit only at about 2 bits per weight.
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
- Size: about 63-66 GB [pinggy].
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
- Size: under 0.5 GB at Q4_0.
- Not a coding or math model: it's for testing the engine and the
  tools around it. It loads in moments, it's fast (about 480 tokens/s
  generation, measured; see `local-ai-plan.md`), and it still answers
  simple questions and makes tool calls, so a test checks something
  real.
- Cons: too small for real work; its card warns of endless repetition,
  which a higher `presence_penalty` reduces [qwen3-06].

## Specialists

Not surveyed yet. `initial-models.yaml` has FLUX.2-klein-4B for making images.

## References

[qwen38]: https://huggingface.co/Qwen/Qwen3.8-27B "Qwen3.8-27B model card"
[laguna]: https://huggingface.co/poolside/Laguna-S-2.1 "Laguna S 2.1 model card"
[laguna-gguf]: https://huggingface.co/poolside/Laguna-S-2.1-GGUF "poolside's Laguna S 2.1 GGUFs"
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
