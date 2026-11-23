# Network plan: default-deny egress for every AI agent

Status (2026-11-18): draft. The repo changes are written and pass
`ci.sh` and `tests/agent-network-test.sh`, but aren't installed or
committed yet (see "Rollout").

Until now every harness (Claude Code via `noclaude`, pi via `nopi`, and
later goose) ran under a nono profile with no network policy, so the
agent, and every command it runs, could reach any host on the ports the
VM's nftables allows (DNS, 22, 80, 443), and could send DNS queries
anywhere. A prompt-injected model could send data anywhere.

This plan limits every agent to an allowlist of hosts, limits *how* it
may use hosts that accept writes, and blocks DNS from the sandbox,
while keeping the agents usable for normal coding work. It's for normal
VMs, where the data isn't very sensitive; I also want it to be an
example others can copy. The secure VM needs more (see "Not in this
plan").

## Design in brief

* **Use nono as intended, and add only what's missing.** The shared
  policy starts from nono's own `developer` network profile (package
  registries, GitHub, GitLab, documentation, sigstore, and model
  providers), then adds method rules and a few hosts.
* **One shared place.** That policy is the `network` section of
  `nono-default-profile.json`, installed as nono's `default` profile,
  which every harness pack (`nolabs-ai/claude`, `nolabs-ai/pi`, ...)
  extends. So every harness gets it, and trying a new harness doesn't
  mean redoing the security work.
* **Small per-harness additions as data.** A harness that needs more
  gets a tiny profile extending its pack (`nono-claude-profile.json`),
  or a flag in its wrapper (`nopi`'s engine port).
* **No new launcher code.** Each wrapper stays one
  `exec anon-access nono run ...` line, and nono's own
  `NONO_ALLOW_DOMAIN` adds a host for one run.
* **Broad by default, narrow under `~/sensitive`.** Most work isn't
  sensitive, so outside `~/sensitive` the agent may read (GET and HEAD)
  the whole web; see 8. The narrow allowlist above is the whole policy
  only under `~/sensitive`.

## What the tests showed

Run on mytux on 2026-11-18 with nono 0.80.0, using throwaway profiles in
`,nono-test/`. Every request went to a local stand-in server on
127.0.0.1, or to public endpoints with no credentials (or an obviously
fake token where a token mattered).

* **nono's proxy mode blocks DNS.** With any `allow_domain` or
  `network_profile` (or `--block-net`), `getent hosts` fails inside the
  sandbox and creating a UDP socket fails with E&#80;ERM. Only nono's proxy
  resolves names, and nono's source (`crates/nono-proxy/src/filter.rs`,
  `check_host`) checks a host against the allowlist *before* resolving
  it, so a denied name never reaches DNS. So proxy mode gives
  default-deny egress and no DNS exfiltration from the sandbox, in one
  step.
* **Unlisted hosts are refused** (no connection; HTTP 403 from the
  proxy). At exit, nono lists each denied host and the `--allow-domain`
  flag that would allow it.
* **A network policy in the `default` profile reaches the packs**
  (`nolabs-ai/pi` and `nolabs-ai/claude` both picked it up).
* **Endpoint rules work as documented, and layer well.** A domain
  entry with `endpoints` makes nono intercept TLS and allow only
  matching method and path. `*` matches exactly one path segment and
  `**` any number; `/**/git-upload-pack` matched a GitLab subgroup
  project. The query string is ignored. `%2F`, `..`, and `//` in a path
  were refused rather than normalized. A trailing slash matched the
  rule without it. A GET rule doesn't cover HEAD or OPTIONS.
  * Rules for a host override a plain listing of it in the
    `network_profile`: with `developer` (which lists `api.github.com`
    plainly) plus a GET-only rule for it, a REST POST got nono's 403.
  * Rules for the same host merge, across `extends` and within one
    file: a harness profile adding `*` on `/**` to a host the default
    limits to GET and HEAD let POSTs through for that harness only.
  * `deny_domain` refuses a host the `network_profile` allows.
* **Tools accept the interception.** nono sets `SSL_CERT_FILE`,
  `CURL_CA_BUNDLE`, `GIT_SSL_CAINFO`, `NODE_EXTRA_CA_CERTS`,
  `REQUESTS_CA_BUNDLE`, and `AWS_CA_BUNDLE` to its session CA. curl,
  git, gh, Node, and npm all worked through it.
* **git and gh work with method rules.** `git ls-remote` and a shallow
  `git clone` worked with GitHub allowing only GET, HEAD, and
  `POST /*/*/git-upload-pack`. gh's GraphQL commands (`gh repo view`,
  `gh pr list`) need `POST /graphql`; with it allowed they reached
  GitHub. REST writes (`gh api -X POST`, `-X PATCH`) got nono's 403.
* **A credential route doesn't stop an attacker's token for gh.** On a
  nono credential route's own reverse-proxy URL, nono accepts only its
  phantom token. But defining the route also lets ordinary
  forward-proxied requests reach that upstream, and those keep whatever
  `Authorization` header the client sent. gh connects to
  `api.github.com` directly, so a credential route can't control which
  token gh's requests carry.
* **A localhost port needs `--open-port`.** In proxy mode, `--open-port
  PORT` let curl and Node's `fetch` reach a stand-in on 127.0.0.1;
  `--allow-connect-port` didn't (it works only with `--block-net`). The
  engine's tunnel wasn't up, so pi itself hasn't been tested this way.
* **Capability elevation doesn't cover network access**; it only traps
  file access. An unlisted host is just refused.
* **`NONO_ALLOW_DOMAIN` adds one host, and only without
  `--allow-domain`.** nono reads it (one host; comma- and
  space-separated lists didn't work) only when the command line has no
  `--allow-domain`. So harness hosts belong in a profile, not in
  wrapper flags.
* **Profiles extend by name only** (a profile in
  `~/.config/nono/profiles`, or a pack), not by file path.
* **Missing from `developer`:** GitHub release downloads now redirect to
  `release-assets.githubusercontent.com`.
* **Unrelated, found on the way:** npm fails in the sandbox because
  `~/.npm` isn't writable. It shouldn't be (it'd be shared between
  projects), so npm's cache now goes inside the working directory.

## Mechanisms, and why

### 1. Proxy mode from nono's `developer` profile (default deny)

`"network_profile": "developer"` turns on nono's proxy with nono's own
maintained host list, so:

* any host not allowed is refused;
* the sandbox can't make DNS queries or open non-proxied sockets;
* other ports (e.g., SSH to anywhere) are unreachable.

Using nono's list as intended means nono's maintainers keep it current,
and our file holds only our differences.

### 2. Method rules for every host that could take a write

Data can only leak to an endpoint the attacker can read back. A
prompt-injected model can't use my credentials (the sandbox has none
that write), but it can use an *attacker's* credentials, pasted into a
page or issue it reads: e.g., post a comment, publish a package, upload
a file to a model provider, or edit a wiki page under the attacker's
account. So the shared profile gives GET and HEAD rules (plus a few
read-only POSTs) to every allowed host with accounts, an API, or
editable pages, including `developer`'s hosts:

* **Model providers** (all 16 in `developer`): GET and HEAD only, so
  they're useless for uploading. A harness that uses one adds more
  methods in its own profile (see 5).
* **Sigstore**: GET and HEAD only; Rekor accepts anonymous uploads to
  a public log.
* **Package registries** (npm, yarn, PyPI, crates.io, RubyGems,
  Packagist, Maven, Gradle) and container registries (ghcr.io,
  registry.gitlab.com): GET and HEAD, so nothing can be published, plus
  npm's audit POSTs.
* **GitHub and GitLab**: see 3.
* **MDN and Microsoft Learn**, which have accounts: GET and HEAD.

Pure download hosts and static documentation with no write path (e.g.,
`files.pythonhosted.org`, `raw.githubusercontent.com`,
`docs.python.org`) stay plain, without interception, which is simpler
and less likely to break a tool.

### 3. GitHub and GitLab: method rules plus the read-only token

GitHub is required, and it's writable by millions of accounts, so it
gets layered rules:

* `github.com`: GET and HEAD, and POST only to `/*/*/git-upload-pack`
  and `/*/*.git/git-upload-pack` (fetch and clone). Push
  (`git-receive-pack`) and web-form POSTs are refused.
* `api.github.com`: GET and HEAD, and `POST /graphql`, so gh's read
  commands work. REST writes are refused.
* `gitlab.com`: GET and HEAD, and `POST /**/git-upload-pack` (projects
  can be in subgroups).
* `anon-access` already gives the sandbox only `GH_PUBLIC_TOKEN`
  (read-only, public repositories), so GraphQL mutations made with *our*
  token fail at GitHub.

**Accepted risk:** a GraphQL mutation carrying an attacker's token
(e.g., `addComment` on the attacker's repo) would pass both nono and
GitHub. Closing that needs body inspection or a proxy that replaces the
`Authorization` header on forwarded requests, which nono doesn't do
today. It needs a working attacker token in the model's input, and
GitHub's secret scanning revokes GitHub tokens posted publicly on
GitHub, which narrows it. I think that's acceptable for normal VMs, not
for the secure VM. It's worth suggesting to nono upstream: an option to
strip or replace client `Authorization` headers on an `allow_domain`
entry.

**Smaller accepted risk:** a GET can carry data in its URL. GitHub repo
owners see traffic stats (counts and popular paths), so a model could
leak a little by fetching paths in an attacker's repo. It's slow and
small.

### 4. Hosts `developer` lacks

`release-assets.githubusercontent.com` (release downloads),
`index.rubygems.org` (bundler's index), GitHub Docs, Hugging Face (model
cards and its model API; GET and HEAD, so nothing can be created or
uploaded, and weights can't be downloaded, since their storage hosts
aren't listed), Wikipedia in every language (`*.wikipedia.org`; GET and
HEAD, since anyone can edit), four Stack Exchange sites (GET and HEAD;
anyone can post), hosts our projects read (CircleCI's API, the
OpenSSF Best Practices site, openssf.org, and Linux Foundation
training, all GET and HEAD since they have accounts or APIs; and
best.openssf.org), and documentation we use (POSIX, man7, Ubuntu
manpages, GNU, Ruby and ruby-lang.org, Rails, Renovate, RFCs, nono).
I found those project hosts by checking 15 recent session transcripts
for hosts that the new policy would refuse.

Wikipedia's Talk pages can't be excluded: nono's rules only allow
paths, `/wiki/*` also matches `/wiki/Talk:Unix`, and the same page is
reachable as `/w/index.php?title=Talk:Unix` (rules ignore the query
string). They're no more writable than articles under these rules, so
it's a question of source quality, not exfiltration; if it matters,
it's guidance for the agents, not network policy.

### 5. Per-harness additions

* **noclaude:** `nono-claude-profile.json`, installed as the
  `bulkhead-claude` profile, extends `nolabs-ai/claude` and allows any
  method on Anthropic's hosts (`api.anthropic.com`, `claude.ai`,
  `platform.claude.com`), on top of the shared GET and HEAD rules. It's
  a profile, not `--allow-domain` flags in `noclaude`, so that
  `NONO_ALLOW_DOMAIN` still works. Claude Code may need more (e.g., for
  updates); nono's exit report will say, and those hosts go there.
* **nopi:** `--open-port` for the engine's tunnel; pi needs no remote
  model provider. The port comes from `infer-models --url` (new: print
  the engine's URL without contacting it), so it works even when the
  engine is down. nono's proxy sets `NO_PROXY=localhost,127.0.0.1`, so
  pi connects directly. `--open-port` also lets the sandbox *listen* on
  that port; that matters only while the tunnel is down, and anything
  on the VM could already answer there (which is why
  `infer-models.jq` checks the answer).
* **goose (later):** a small profile extending its pack, like Claude's,
  or `--open-port` for the local engine.

### 6. Adding hosts without mid-session prompts

Capability elevation doesn't cover network access, and I don't want
constant prompts anyway, so hosts are added between sessions: at exit
nono lists refused hosts. Set `NONO_ALLOW_DOMAIN` for a one-off (one
host, any method, e.g., `NONO_ALLOW_DOMAIN=docs.example.org noclaude`),
or add the host to the shared profile (with GET and HEAD rules unless
it's a pure download host).

### 7. Caches stay per directory

`anon-access` already points `XDG_CACHE_HOME` at `$PWD/.cache`, so one
project's tools can't poison another's cache. npm ignores that, so
`anon-access` also sets `npm_config_cache="$XDG_CACHE_HOME/npm"`.

`nolabs-ai/claude` sets `TMPDIR` to `~/.claude/tmp/claude-$UID`, shared
by every Claude session, which overrides `anon-access`'s
`TMPDIR=$PWD/.tmp`. So `bulkhead-claude` sets `TMPDIR` and
`CLAUDE_CODE_TMPDIR` to `$TMPDIR`, which nono expands to the value it
was started with (tested): `anon-access`'s per-directory one, which
already exists inside the granted current directory. This also keeps
`nono why --self` working: it refuses a `NONO_CAP_FILE` outside the
current `TMPDIR`, and outer nono writes that file in its own `TMPDIR`
(tested: with the pack's `TMPDIR` it fails, with ours it works). A
harness profile that sets `TMPDIR` must keep it at or above the outer
one for the same reason.

### 8. Broad by default, narrow under `~/sensitive`

(Added 2026-11-19, tested on nono 0.82.) The narrow allowlist refused
too much normal work, and most of my work isn't sensitive. So
`anon-access` adds `--extends bulkhead-broad` to every `nono run`
unless the real current directory is under `~/sensitive`. It's in
`anon-access` because nono has no environment variable for `--extends`,
and that way every harness gets it.

`bulkhead-broad` (`nono-broad-profile.json`) allows GET and HEAD to
every host. nono 0.82 refuses even GET when `"*"` has endpoint rules,
but accepts `"*.<tld>"` with them, so the profile has one such entry
per IANA TLD, generated by `update-broad-profile.sh`. It leaves out the
internationalized (`xn--`) TLDs, since nono refuses to start with some
of them. What I found in testing:

* A host with its own endpoint rules gets the union of its rules and
  the wildcard's, so GitHub's fetch and GraphQL POSTs, npm's audit
  POSTs, and `bulkhead-claude`'s Anthropic rules still work.
* A plain host entry (no endpoint rules) doesn't escape a matching
  wildcard's rules, in either order: it becomes GET and HEAD only, and
  TLS-intercepted rather than tunneled. That's fine for the plain hosts
  in the narrow list, which are download and documentation hosts, but
  it means `NONO_ALLOW_DOMAIN` can't add POST in broad mode.
* `deny_domain` beats both `"*"` and the wildcards, including wildcard
  deny entries. So the shared profile's `deny_domain` refuses known
  exfiltration sinks (request catchers, OAST hosts, tunnels, and paste
  sites) in both modes. GET-only doesn't stop exfiltration: an
  attacker's own host can log query strings. The deny list only removes
  the ready-made sinks.

Files written in broad mode are untrusted if you later move them into
`~/sensitive`.

nono's `approval_backends` (ask before connecting to an unlisted host)
might suit `~/sensitive`; I haven't tried it.

## Data format

Both profiles are nono's own JSON, one line per host, so they're easy
to read, diff, and process with `jq` (e.g.,
`jq -r '.network.allow_domain[] | .domain? // .' nono-default-profile.json`
lists the hosts). `ci.sh` checks that every rule names a method and a
path.

## Files

* `nono-default-profile.json`: add the `network` section.
* `nono-claude-profile.json` (new): `bulkhead-claude`.
* `nono-broad-profile.json` (new, generated by the new
  `update-broad-profile.sh`): `bulkhead-broad`.
* `anon-access`: add `--extends bulkhead-broad` outside `~/sensitive`.
* `noclaude`: use `--profile bulkhead-claude`.
* `nopi`: add `--open-port` for the engine's tunnel.
* `infer-models.template.sh`: add `--url`.
* `anon-access`: set `npm_config_cache`.
* `vm-setup.sh`: install `nono-claude-profile.json` and
  `nono-broad-profile.json`.
* `ci.sh`: check both profiles and `infer-models --url`; shellcheck the
  new test.
* `tests/agent-network-test.sh` (new, run by hand in a VM, since it
  needs nono and the network): checks DNS is blocked, unlisted hosts
  and writes are refused, and reads, gh's GraphQL, and git fetch work.
* `AGENTS.md`: keep security policy shared across harnesses, and reuse
  existing tools as intended.
* `README.md`: describe the new files.

## Rollout

nono binds its policy when a session starts, so installing this changes
only new sessions. Since it changes `noclaude` too, test before
installing, without touching `~/.config/nono`:

1. `tests/agent-network-test.sh nolabs-ai/pi nono-default-profile.json`,
   and the same with `nolabs-ai/claude`. These passed on 2026-11-18
   (GraphQL was skipped for GitHub's anonymous rate limit, after it had
   passed in earlier tests).
2. Try Claude Code with the combined policy, from a scratch directory:

   ```sh
   jq -s '{meta: {name: "claude-test"}, extends: "nolabs-ai/claude",
       network: (.[0].network + {allow_domain:
         (.[0].network.allow_domain + .[1].network.allow_domain)})}' \
     ~/projects/bulkhead/nono-default-profile.json \
     ~/projects/bulkhead/nono-claude-profile.json > ,claude-test.json
   anon-access nono run --profile ./,claude-test.json --allow-cwd -- claude
   ```

   Use it normally for a while; at exit nono lists any hosts it refused.
   Add the ones Claude Code itself needs to `nono-claude-profile.json`.
3. Then run `vm-setup.sh` and restart each harness's session.

## Not in this plan

* **The secure VM.** It should have essentially no network (UTM "Host
  Only", plus `--block-net` with only the tunnel port), per the lethal
  trifecta discussion in `,research.md`.
* **The VM's nftables.** Limiting port 53 to the VM's resolver is cheap
  and worth doing for everything else on the VM, but it's separate.
* **Narrowing Claude Code's API use** to the paths it needs (e.g.,
  `POST /v1/messages`). Worth trying once the basic list works.

## Open questions

* Does pi itself reach the engine with the proxy set? I expect so;
  test with the tunnel up.
* Exactly which hosts does Claude Code need? Probably more than its API
  hosts: e.g., for updates and for claude.ai's MCP connectors. Its
  WebFetch tool fetches from the VM, so it'll be limited to the
  allowlist too; that's intended, but it'll be the most visible change.
* Should the Stack Exchange sites be in the shared list? I think
  they're useful enough, with GET and HEAD rules.
