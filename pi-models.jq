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
# every level gets the server's --reasoning-budget. thinkingFormat
# "chat-template" makes pi send chatTemplateKwargs, which llama-server
# gives the model's chat template: enable_thinking turns thinking on
# unless the level is "off", and reasoning_effort tells the model how
# hard to think, so that matches the budget. Qwen3.8's template takes
# low, medium, and xhigh (and fails on anything else), hence
# thinkingLevelMap; a template without these ignores them.
# preserve_thinking keeps earlier turns' thinking in the prompt (pi sends
# it back as reasoning_content); it's Qwen3.8's default anyway.
{
  "$schema": "https://pi.dev/schemas/models.schema.json",
  providers: {"mac-local": {
    baseUrl: .url,
    api: "openai-completions",
    apiKey: "${INFER_API_KEY}",
    compat: {
      thinkingTokenBudgetField: "thinking_budget_tokens",
      thinkingFormat: "chat-template",
      chatTemplateKwargs: {
        enable_thinking: {"$var": "thinking.enabled"},
        reasoning_effort: {"$var": "thinking.effort", omitWhenOff: true},
        preserve_thinking: true
      }
    },
    models: [.models[] | select(.output | any(. == "text")) | {
      id: .id,
      name: (.name + (if .variant_of != null then " (\(.id))" else "" end)),
      input: (if .input | any(. == "image") then ["text", "image"] else ["text"] end),
      reasoning: true,
      thinkingLevelMap: {minimal: "low", low: "low", medium: "medium", high: "xhigh", xhigh: "xhigh"},
      contextWindow: .context,
      maxTokens: .max_tokens
    }]
  }}
}
