# check_llama_swap_config.py: checks llama-swap's config, as
# infer_llama_swap_yaml (host-models.sh) renders it from
# initial-models.yaml, for what pi and nopi need from it. Run by ci.sh,
# since llama-swap isn't there to check it:
#   python3 -I tests/check_llama_swap_config.py CONFIG.yaml
# Each model's context matches its --ctx-size, max_tokens fits in it,
# and exactly one model is the default. Fails (an AssertionError) on the
# first problem.
import re
import sys

import yaml

cfg = yaml.safe_load(open(sys.argv[1]))
assert cfg["apiKeys"] == ["sk-test"], "the API key isn't ours alone"
assert cfg["captureBuffer"] == 0, "llama-swap must not keep prompts and replies"
assert cfg["globalTTL"] == 86400, "llama-swap should keep an idle model loaded for a day"
defaults = []
for name, m in cfg["models"].items():
    ctx = (m.get("capabilities") or {}).get("context")
    max_tokens = (m.get("metadata") or {}).get("max_tokens")
    if m["cmd"].startswith("${sd-server} "):
        assert m["capabilities"]["out"] == ["image"], f"{name}: needs capabilities.out: [image]"
        assert m["proxy"] == "${specialist-proxy}", f"{name}: a specialist needs its own port"
        assert 0 < m["ttl"] <= 3600, f"{name}: a specialist must unload within an hour"
        continue
    assert m["proxy"] == "${proxy}", f"{name}: a generalist needs the generalist port"
    assert "ttl" not in m, f"{name}: a generalist should stay loaded (globalTTL)"
    size = re.search(r"--ctx-size (\d+)", m["cmd"])
    assert isinstance(ctx, int) and size and int(size.group(1)) == ctx, \
        f"{name}: capabilities.context must match --ctx-size"
    assert isinstance(max_tokens, int) and 0 < max_tokens <= ctx, \
        f"{name}: metadata.max_tokens must be a number up to the context"
    if (m.get("metadata") or {}).get("default") is True:
        defaults.append(name)
assert len(defaults) == 1, f"exactly one model needs metadata.default: true, not {defaults}"
# One group per role, which swaps within itself and leaves the other
# alone, and every model in one; otherwise llama-swap's default group
# would evict both.
groups = cfg["routing"]["router"]["settings"]["groups"]
assert cfg["routing"]["router"]["use"] == "group" and set(groups) == {"generalists", "specialists"}
for g in groups.values():
    assert g["swap"] is True and g["exclusive"] is False, "each role must swap only within itself"
roles = {n: "specialists" if m["cmd"].startswith("${sd-server} ") else "generalists"
         for n, m in cfg["models"].items()}
for gname, g in groups.items():
    assert sorted(g["members"] or []) == sorted(n for n, r in roles.items() if r == gname), \
        f"{gname}: members {g['members']} don't match the models' roles"
macros = cfg["macros"]
assert "--port 8999 " in macros["llama-server"] and macros["proxy"] == "http://127.0.0.1:8999"
assert macros["sd-server"].endswith("--listen-port 8998") and macros["specialist-proxy"] == "http://127.0.0.1:8998"
