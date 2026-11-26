# goose-llama-swap.jq: goose's llama_swap provider
# (~/.config/goose/custom_providers/llama_swap.json), from infer-models'
# output: goose's own definition (llama_swap.json in goose's
# crates/goose-providers/src/declarative/definitions, v1.60.1), plus
# each model and variant the engine serves that outputs text, with its
# context window and maximum reply length. goose loads a custom provider
# after its built-in ones, so this one replaces the built-in llama_swap.
# The models matter only until goose refreshes the provider's model list
# itself: goose 1.60.1's app shows a provider's own models until then,
# and it refreshes only when you check the provider's connection in its
# settings, so without these its model picker would be empty. compart
# goose and compart goose-desktop run this each time goose starts (and
# set LLAMA_SWAP_HOST and LLAMA_SWAP_API_KEY); vm-setup.sh installs it
# in /usr/local/libexec/bulkhead.
{
  name: "llama_swap",
  engine: "openai",
  display_name: "Llama Swap",
  description: "Local proxy that hot-swaps llama.cpp (and other) inference backends on demand via an OpenAI-compatible API. Here, the Mac's local AI engine, through this VM's tunnel (written by compart).",
  api_key_env: "LLAMA_SWAP_API_KEY",
  base_url: "${LLAMA_SWAP_HOST}/v1/chat/completions",
  env_vars: [{
    name: "LLAMA_SWAP_HOST",
    required: false,
    secret: false,
    primary: true,
    default: "http://localhost:8080",
    description: "Base URL of the llama-swap proxy (compart sets it)"
  }],
  dynamic_models: true,
  models: [.models[] | select(.output | any(. == "text")) | {
    name: .id,
    context_limit: .context,
    max_tokens: .max_tokens
  }],
  supports_streaming: true,
  requires_auth: false,
  skip_canonical_filtering: true
}
