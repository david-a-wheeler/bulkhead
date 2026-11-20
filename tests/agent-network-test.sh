#!/bin/sh
# agent-network-test.sh: check the shared network policy (the "network"
# section of nono-default-profile.json; see agent-network-plan.md) from
# inside a harness's nono sandbox. Run it by hand in a VM, not in CI: it
# needs nono and the network. It only reads public data; the writes it
# tries carry no credentials, and nono should refuse them before they
# leave the VM.
#
# Usage: tests/agent-network-test.sh [--broad] [PACK [PROFILE-FILE]]
#
# PACK is the harness's nono pack (default nolabs-ai/pi). By default the
# test uses the installed policy (the pack extends nono's "default"
# profile). With PROFILE-FILE (e.g., this repo's nono-default-profile.json,
# before vm-setup.sh installs it), it uses that file's "network" section
# instead, through a throwaway profile ,agent-network-test.json in the
# current directory that extends PACK.
#
# With --broad, it tests the broad mode that anon-access uses outside
# ~/sensitive: it adds the installed bulkhead-broad profile (or, with
# PROFILE-FILE, this repo's nono-broad-profile.json), and expects
# unlisted hosts to allow GET but refuse POST.
#
# Unauthenticated GitHub API calls are limited to 60 an hour; if that
# runs out, those checks say SKIP rather than fail.
set -eu

if [ -z "${NONO_CAP_FILE:-}" ]; then
  # Not sandboxed yet: rerun this script under nono.
  dir=$(cd "$(dirname "$0")" && pwd)
  mode=narrow
  if [ "${1:-}" = --broad ]; then
    mode=broad
    shift
  fi
  pack="${1:-nolabs-ai/pi}"
  profile="$pack"
  profile_file="${2:-}"
  set --
  if [ -n "$profile_file" ]; then
    profile=./,agent-network-test.json
    broad_file=/dev/null
    [ "$mode" = narrow ] || broad_file="$dir/../nono-broad-profile.json"
    jq -n --arg pack "$pack" --slurpfile p "$profile_file" --slurpfile b "$broad_file" \
      '{meta: {name: "agent-network-test"}, extends: $pack,
        network: ($p[0].network + {allow_domain:
          ($p[0].network.allow_domain + ($b[0].network.allow_domain // []))})}' \
      > "$profile"
  elif [ "$mode" = broad ]; then
    set -- --extends bulkhead-broad
  fi
  exec nono run -s "$@" --profile "$profile" --allow-cwd --read "$dir" -- \
    "$dir/$(basename "$0")" "$mode"
fi
mode="${1:-narrow}"

fails=0
skips=0
# outcome METHOD URL [CURL-OPTION...]: print "refused" if nono's proxy
# refused the request (the host isn't allowed, so there's no HTTP answer;
# or the method and path aren't, so it answers 403 with its own body),
# "rate-limited" for GitHub's limit, or else the HTTP status.
outcome() {
  m=$1 u=$2
  shift 2
  body=$(curl -s -m 20 -X "$m" -o - -w '\n%{http_code}' "$@" "$u" 2>/dev/null) || :
  status=$(printf '%s\n' "$body" | tail -n 1)
  body=$(printf '%s\n' "$body" | sed '$d')
  if [ "$status" = 000 ] || { [ "$status" = 403 ] && [ "$body" = '{"error":"Forbidden"}' ]; }; then
    echo refused
  elif [ "$status" = 403 ] && printf '%s' "$body" | grep -q 'rate limit exceeded'; then
    echo rate-limited
  else
    echo "$status"
  fi
}
# check NAME ACTUAL EXPECTED...: pass if ACTUAL is one of EXPECTED.
check() {
  name=$1 actual=$2
  shift 2
  if [ "$actual" = rate-limited ]; then
    echo "SKIP: $name (GitHub's rate limit)"
    skips=$((skips + 1))
    return
  fi
  for want in "$@"; do
    if [ "$actual" = "$want" ]; then
      echo "ok:   $name ($actual)"
      return
    fi
  done
  echo "FAIL: $name (got $actual, expected $*)"
  fails=$((fails + 1))
}
# fetch NAME URL: pass if git can list the repository's refs.
fetch() {
  if git ls-remote "$2" HEAD > /dev/null 2>&1; then r=ok; else r=failed; fi
  check "$1" "$r" ok
}

if getent hosts example.org > /dev/null 2>&1; then r=resolved; else r=blocked; fi
check "DNS from the sandbox is blocked" "$r" blocked
if [ "$mode" = broad ]; then
  check "an unlisted host allows GET" "$(outcome GET https://example.com/)" 200
  check "an unlisted host refuses POST" "$(outcome POST https://example.com/ -d x=1)" refused
else
  check "an unlisted host is refused" "$(outcome GET https://example.com/)" refused
fi
check "a known exfiltration sink is refused" "$(outcome GET https://webhook.site/)" refused
check "GitHub API GET" "$(outcome GET https://api.github.com/zen)" 200
check "GitHub API HEAD" "$(outcome HEAD https://api.github.com/zen -I)" 200
check "GitHub GraphQL POST reaches GitHub" \
  "$(outcome POST https://api.github.com/graphql -d '{"query":"{viewer{login}}"}')" 200 401
check "GitHub REST POST is refused" "$(outcome POST https://api.github.com/markdown -d '{}')" refused
check "GitHub push is refused" \
  "$(outcome POST https://github.com/nolabs-ai/nono.git/git-receive-pack)" refused
fetch "git fetch from GitHub" https://github.com/nolabs-ai/nono
fetch "git fetch from a GitLab subgroup" \
  https://gitlab.com/gitlab-org/security-products/analyzers/semgrep
check "a download host" \
  "$(outcome GET https://raw.githubusercontent.com/nolabs-ai/nono/main/README.md)" 200
check "a documentation site" "$(outcome GET https://docs.python.org/3/)" 200
check "Wikipedia POST is refused" "$(outcome POST https://en.wikipedia.org/w/api.php)" refused
check "a Hugging Face model card" \
  "$(outcome GET https://huggingface.co/Qwen/Qwen3-0.6B/raw/main/README.md)" 200
check "a Hugging Face POST is refused" "$(outcome POST https://huggingface.co/api/repos/create)" refused
# Model providers are in nono's "developer" profile; the shared policy
# makes them read-only (a harness that needs one adds it in its own
# profile), so a model can't upload files with an attacker's API key.
check "a model provider's POST is refused" "$(outcome POST https://api.openai.com/v1/files)" refused
check "a Rekor upload is refused" \
  "$(outcome POST https://rekor.sigstore.dev/api/v1/log/entries)" refused

echo "$fails failed, $skips skipped."
[ "$fails" -eq 0 ]
