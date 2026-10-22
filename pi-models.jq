# pi-models.jq: pi's ~/.pi/agent/models.json, from infer-models' output:
# one "mac-local" provider, reached through the VM's tunnel, with every
# model and variant the engine serves that outputs text (pi can only
# chat). nopi runs it each time pi starts; vm-setup.sh installs it in
# /usr/local/libexec/bulkhead.
# pi reads the literal ${INFER_API_KEY} from its environment (nopi sets
# it), so the key never goes in the file. pi sends images only to a model
# that says it takes them. Every model so far is a reasoning model.
# thinkingTokenBudgetField makes pi send each thinking level's budget
# (e.g., 8192 for "medium") in the field llama-server reads; otherwise
# every level gets the server's --reasoning-budget. thinkingLevelMap
# makes "off" send reasoning_effort "none", which turns thinking off;
# otherwise pi sends nothing and the model still thinks.
{
  "$schema": "https://pi.dev/schemas/models.schema.json",
  providers: {"mac-local": {
    baseUrl: .url,
    api: "openai-completions",
    apiKey: "${INFER_API_KEY}",
    compat: {thinkingTokenBudgetField: "thinking_budget_tokens"},
    models: [.models[] | select(.output | any(. == "text")) | {
      id: .id,
      name: (.name + (if .variant_of != null then " (\(.id))" else "" end)),
      input: (if .input | any(. == "image") then ["text", "image"] else ["text"] end),
      reasoning: true,
      thinkingLevelMap: {off: "none"},
      contextWindow: .context,
      maxTokens: .max_tokens
    }]
  }}
}
