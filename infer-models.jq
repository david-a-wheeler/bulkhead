# infer-models.jq: infer-models' answer, from the engine's /v1/models
# listing (llama-swap's), given the engine's URL as $url. infer-models
# runs it; vm-setup.sh installs it in /usr/local/libexec/bulkhead.
# Anything on the VM could answer on the engine's port while the tunnel
# is down, so the listing is untrusted: this fails unless each name uses
# only letters, digits, ".", "_", ":", and "-", each model that outputs
# text has a context window and a maximum reply length, and at most one
# model is the default. jq writes the JSON, so the listing can't inject
# anything into it.
def plain: type == "string" and test("^[A-Za-z0-9._:-]+$");
def number: type == "number" and . > 0;
def modalities: type == "array" and all(.[]; type == "string");
[.data[] | {
  id,
  name: (if (.name | type) == "string" and .name != "" then .name else .id end),
  variant_of: (if .meta.llamaswap.type == "alias" then .meta.llamaswap.modelID else null end),
  default: (.meta.llamaswap.default == true and .meta.llamaswap.type != "alias"),
  context: .context_length,
  max_tokens: .meta.llamaswap.max_tokens,
  input: (.architecture.input_modalities // ["text"]),
  output: (.architecture.output_modalities // ["text"])
}
| if (.id | plain | not) then error("bad model name: \(.id)")
  elif .variant_of != null and (.variant_of | plain | not) then error("\(.id) is a variant of a bad model name")
  elif (.input | modalities | not) or (.output | modalities | not) then error("\(.id) has bad modalities")
  elif (.output | any(. == "text")) and ((.context | number | not) or (.max_tokens | number | not))
  then error("\(.id) lacks capabilities.context or metadata.max_tokens")
  elif (.output | any(. == "text") | not) then .context = null | .max_tokens = null
  else . end]
| [.[] | select(.default) | .id] as $defaults
| if ($defaults | length) > 1 then error("more than one default: \($defaults | join(", "))") else . end
| {url: $url, default: ($defaults[0] // null), models: map(del(.default))}
