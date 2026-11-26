# goose-models.jq: goose desktop's GOOSE_PREDEFINED_MODELS, from
# infer-models' output: each model and variant the engine serves that
# outputs text, through goose's llama_swap provider, with its context
# window. compart goose-desktop runs it each time the app starts, so the
# app's model picker lists what llama-swap serves, without the app
# having to fetch the list itself (goose 1.60.1 doesn't, until you
# check the provider's connection in its settings). vm-setup.sh
# installs it in /usr/local/libexec/bulkhead.
[.models[] | select(.output | any(. == "text")) | {
  name: .id,
  provider: "llama_swap",
  alias: (.name + (if .variant_of != null then " (\(.id))" else "" end)),
  context_limit: .context
}]
