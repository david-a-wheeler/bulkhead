# Threat model: per-directory compartments (draft)

Status: a working draft, for discussion. Drafted by Claude for now.
It's meant to become a real
threat model, starting from security requirements. For now it tries
to do two things: name *realistic* requirements for per-directory
compartments, and list many ways to meet each one, so we can pick a
simpler design than the one we've been building.

It doesn't change anything yet, and it doesn't replace README.md's
threat model, which still describes what's built.

## Why rethink this

The VM layer works and I'm keeping it: separate VMs for, e.g., work,
personal, and especially sensitive projects, with my most important
files and every secret on the Mac. It's simple to reason about, and
its boundary is strong (a hypervisor, plus a secrets server that asks
me before releasing anything).

The per-directory compartments inside each VM are another matter.
We've tried to make them prevent *every* bad outcome, and each new
use case (web search with POST, GUI programs, copying text out of a
GUI) has needed another special mechanism. The weston clipboard work
is a good example: three layers of sandboxing and an X server, so
text can cross one way. That's a straitjacket, and it's getting hard
to understand and maintain, which is itself a security problem.

So I want requirements that limit *damage* and make misbehavior
*harder and more likely to be noticed*, instead of trying to prevent
all of it.

## What we're protecting (assets)

Roughly in order of how bad a loss would be:

1. **Credentials**: GitHub, Heroku, cloud accounts, SSH and GPG keys,
   and anything that lets someone act as me. These live on the Mac.
2. **My identity and reputation online**: anything done from my IP
   address or accounts looks like me (e.g., an attack on a website, or
   spam from my GitHub account).
3. **Files outside the compartment**: other projects in the same VM,
   my VM home directory, the Mac, and other VMs.
4. **Systems near me**: the Mac's services, other VMs, and my home or
   office LAN (e.g., the router's admin page, printers, NAS).
5. **The compartment's own files**: the project, its git history, and
   whatever I put in its inbox. Some projects are public anyway; some
   aren't.
6. **Availability**: the VM's CPU, memory, and disk; my paid model
   quotas.

## Who and what we're defending against

The main threat: **an agent that reads malicious input and "goes
rogue".** It reads a web page, an issue, a README, a package's
files, or a document that carries instructions (prompt injection), and
then follows them. It runs arbitrary code as my VM user, inside the
compartment. Its typical goals:

- **Exfiltration**: send data it can reach (especially credentials)
  to the attacker.
- **Attack others**: use my machine as a platform to attack external
  systems (scanning, brute force, exploit attempts, spam, abuse of my
  accounts).
- **Persistence and spread**: plant something that runs later outside
  the compartment (e.g., a git hook that runs when *I* run git there,
  a change to a shell startup file, or a poisoned dependency), or
  leave instructions for another agent.

Related threats with the same shape: an agent that's simply mistaken
(e.g., runs a destructive command), a malicious dependency that the
agent installs and runs, and a backdoored model (see research.md,
"Weight-level backdoors").

What I assume an attacker can't do: break the kernel, Landlock, or
the hypervisor *without* a bug. Those bugs exist, but they're why we
have two layers (compartment, then VM), not something compartments
themselves can fix.

## The key fact we have to accept

If an agent (1) can read some data, (2) reads untrusted content, and
(3) can send anything out, it can be tricked into sending that data
out. That's Simon Willison's ["lethal
trifecta"](https://simonwillison.net/2025/Jun/16/the-lethal-trifecta/);
Meta's "Agents Rule of Two" says much the same: an agent should have
at most two of those three (I haven't rechecked that post's details;
I believe it's <https://ai.meta.com/blog/practical-ai-agent-security/>).

Every useful compartment outside `~/sensitive` has all three: it
reads its project, it reads the web, and a GET's URL can carry data.
So does the model's own API: the agent sends its context to the
model provider by design. Content filters (DLP, method rules) only
stop sloppy attempts, since the agent chooses the content and can
encode it.

So the realistic goal for an ordinary compartment isn't "no data
leaves". It's: **only what's in that compartment can leave, nothing
in it is worth much more than the project itself, and leaks are
harder and more likely to be noticed.** Projects whose data must not
leave need a different combination (break one leg of the trifecta),
not more filters.

## Security requirements (proposed)

I've split these into **hard** requirements (we enforce them with a
mechanism the agent can't bypass, and we test them), **soft**
requirements (we make the bad outcome harder, rarer, or more visible,
but don't promise it can't happen), and **non-requirements** (things
we deliberately stop trying to guarantee).

### Hard requirements

- **H1. No credentials.** An agent in a compartment never holds, and
  can't use without my approval, any long-lived credential. (Today:
  the Mac holds them; `anon-access` strips session handles; nono's
  phantom tokens keep the Claude login usable only through its proxy.
  This works and is cheap. Keep it.)
- **H2. Confidentiality is bounded by the compartment.** An agent can
  read only its own workspace, its inbox, its harness state, and
  shared read-only setup. It can't read other compartments, the rest
  of my VM home, the Mac, or other VMs. So in the worst case, it can
  leak only what's in its compartment (and its model context).
- **H3. Integrity outside the compartment.** An agent can't change
  anything outside its compartment, including shared harness setup,
  its own policy and logs, and files that something outside will later
  run (git config and hooks, shell startup files, desktop autostart).
- **H4. No reaching nearby systems.** An agent can't connect to the
  VM's services, the Mac (except the local engine tunnel I open), other
  VMs, or private and local addresses (my LAN, link-local, loopback
  outside its own namespace), even by a public name that resolves to
  one.
- **H5. No acting as me online.** An agent can't send authenticated
  requests as me (my accounts, cookies, or tokens), except where I've
  explicitly granted a limited token (e.g., `gh`'s read-only public
  token).
- **H6. Its own logs are out of its reach.** A record of what it
  reached (hosts, methods, sizes, denials) is kept where it can't
  change or erase it.

### Soft requirements

- **S1. Exfiltration is hard and noisy.** Getting a lot of data out
  should take visible effort: many requests, unusual hosts, long URLs,
  or big uploads, which a log summary or alarm points out.
- **S2. Attacks on others are limited and noisy.** An agent shouldn't
  be able to send high volumes of traffic, reach unusual ports, or
  write (POST, PUT, DELETE) to arbitrary sites quickly or quietly.
  Without credentials (H5), what's left is mostly unauthenticated
  noise, which we want to keep small and visible.
- **S3. Damage within the compartment is recoverable.** I can undo an
  agent's changes to its workspace (snapshots, git).
- **S4. Persistence is detected.** Anything that would run outside
  the compartment later (e.g., git's hooks and filters) is checked and
  needs my approval.
- **S5. A session can be stopped quickly** when something looks wrong.

### Requirements on the design itself

- **D1. Normal work just works.** Searching the web (including search
  engines that use POST), installing packages, running tests and
  servers, and showing a GUI program shouldn't need per-action
  approvals. Friction I hit daily gets turned off, which is worse
  than a weaker control I keep.
- **D2. It's simple enough to understand and audit.** I should be
  able to explain each mechanism in a sentence or two, and say which
  requirement it serves. A mechanism nobody can explain is one nobody
  will notice failing.
- **D3. One policy for every harness** (per AGENTS.md), enforced
  below the harness, so commands the harness runs can't bypass it.

### Non-requirements (stop trying to guarantee these)

- **N1. Preventing every leak of a compartment's own data.** Within an
  ordinary compartment, assume what it can read can leak. Choose what
  goes in it accordingly (or use a sensitive mode; see "Modes" below).
- **N2. Closing covert channels** between compartments, or to the
  outside (timing, DNS-name encoding, and so on). Make them slow, not
  impossible.
- **N3. Preventing denial of service** against the VM itself.
- **N4. Protecting the compartment's desktop window from the
  compartment** (it's showing its own data).
- **N5. Defeating prompt injection itself.** That's the harness's
  and model's job; we limit what an injected agent can do.

## Ways to meet the requirements

For each requirement, here are options, from cheapest to most
involved, with what they cost. "Have" means it's built today.

### H1: no credentials

1. **Have:** secrets on the Mac, released only after approval; the VM
   stores none.
2. **Have:** `anon-access` strips session handles and tokens.
3. **Have:** nono's phantom tokens for the model's login.
4. **Narrow tokens for the rare case:** when an agent truly needs a
   credential (e.g., to open a PR), mint a short-lived, single-repo
   token for that session only, ideally bound to one host by the proxy
   (the proxy injects it only into requests to that host).
5. **Decoys:** put canary credentials (fake AWS keys, a fake
   `~/.netrc`) where an agent might look; if anyone ever uses one, you
   learn of the leak (see S1).

### H2: confidentiality bounded by the compartment

1. **Have:** bwrap gives a compartment its own view of the filesystem;
   nono's Landlock rules limit it further.
2. **Simpler alternative:** nono's Landlock rules alone, without
   bwrap, if we accept that other projects' *names* are visible (but
   not their contents). Fewer moving parts; weaker against Landlock
   bugs.
3. **Keep secrets out of the workspace itself:** have nono deny reads
   of `.env`, `*.pem`, `id_*`, and similar names inside the workspace,
   so a project's own stray secrets don't leak with it.
4. **Put less in each compartment:** work in a fresh clone or
   worktree with only the branch the task needs, instead of a long-lived
   checkout with private branches and old history.
5. **Use the VM boundary for anything truly sensitive:** a project in
   the sensitive VM is out of reach of every compartment in the others,
   whatever bugs they have.

### H3: integrity outside the compartment

1. **Have:** shared setup is read-only inside; the dossier's policy
   and logs aren't reachable.
2. **Have:** `compart` checks git's local settings and hooks, and asks
   me before running git with new ones (see compartments.md, "Git runs
   commands from local files").
3. **Habit:** run code an agent wrote only with `compart sh`, never in
   my own shell. That's a habit, not a mechanism, so it's the weak
   spot; a shell prompt marker or a warning when I `cd` into a
   workspace could help.

### H4: no reaching nearby systems

1. **Have:** pasta gives each compartment its own network namespace,
   so it can't reach the VM's loopback services or other compartments'
   servers; no UDP and no direct TCP except nono's proxy.
2. **Gap to check:** does nono's proxy refuse names that resolve to
   private addresses (RFC 1918, link-local, loopback, CGNAT, IPv6
   ULA and link-local), including after redirects? The VM's nftables
   allows ports 22, 80, and 443 to *any* address, so a public name
   pointing to my router's address might work through the proxy
   today. I haven't tested it. This is the most important open
   question in this document.
3. **Belt and braces at the VM:** have nftables drop the VM's traffic
   to private ranges, except the Mac's ports we use. That protects my
   LAN from the whole VM, not just compartments, and it doesn't depend
   on nono.
4. **Same at the Mac:** the Mac's firewall could refuse the VMs'
   connections except to the ports they need.

### H5: no acting as me online

1. **Have:** follows from H1; there's nothing to act with.
2. **Have:** method rules keep writes to the hosts listed for them
   (e.g., the model's API).
3. **Check:** can an agent use an allowed write host with *its own*
   credentials (e.g., an attacker's API key to the model provider, or
   an anonymous upload site that happens to be allowed)? Every host
   that accepts writes without my login is an exfiltration sink, so
   the list of POST-allowed hosts should name each one's reason.

### H6: logs out of reach

1. **Have:** nono's log and the dossier's `logs/` are outside the
   sandbox.
2. **Add:** a per-session summary at exit (hosts reached, request
   counts, bytes out, denials), so the log gets read; nobody reads raw
   logs. See S1.

### S1: exfiltration is hard and noisy

1. **Volume and shape limits at the proxy:** cap bytes out per session
   and per host, cap URL length (e.g., 2 KB) to unfamiliar hosts, and
   cap the number of distinct hosts per session. Each cap turns a quick
   dump into a slow, visible dribble.
2. **New-host tracking:** keep a per-compartment list of hosts it has
   reached before; report new ones in the session summary, and
   optionally pause (or ask) on a new host after the first N.
3. **Known sinks blocked:** keep a blocklist of paste sites, request
   catchers, tunnels, and out-of-band callback services (nono's
   network profiles may already have some; the other AI's notes in
   `,loosening.md` say so, unverified by me).
4. **Canary strings:** put a unique random token in each compartment
   (e.g., in a file the agent would read, or in its instructions) and
   have the proxy flag any request that contains it. That catches
   naive exfiltration of the whole context. Encoded copies get past
   it, so it's an alarm, not a wall.
5. **Canary credentials:** fake keys from a canary service, which
   alert when anyone tries them, anywhere. That catches exfiltration
   even when it's encoded, once the attacker uses what it stole.
6. **Post-session review:** have a separate model (with no tools)
   read the session's network log and transcript and flag signs of
   injection (instructions in fetched content, odd hosts, long
   encoded URLs). It's cheap, and it doesn't slow the session.
7. **Break the trifecta when it matters:** see "Modes".

### S2: attacks on others are limited and noisy

1. **Have:** no credentials (H1, H5), so most serious abuse is out of
   reach.
2. **Have:** the compartment's only way out is nono's proxy, and the
   other AI's tests found it refuses CONNECT to ports other than 443
   (unverified by me), so no scanning of other ports, SSH brute force,
   or SMTP spam.
3. **Rate limits:** cap requests per second per host and concurrent
   connections per session at the proxy.
4. **Writes:** keep GET and HEAD to the web by default, plus POST to a
   named list (search engines, the model's API, package registries).
   For POST to other hosts, choose one: refuse (today), ask me, or
   allow at a low rate and report it. Method rules don't stop
   exfiltration, but they do limit "submit forms all over the web".
5. **Session summary and alarm** for many 4xx responses from one host
   (a sign of brute force or probing).

### S3 to S5: recovery, persistence, stopping

1. **Have:** snapshots of tracked files at launch; git.
2. **Have:** the git settings check.
3. **Add:** a simple way to stop every process in a compartment (e.g.,
   `compart stop`), and to have the proxy pause one when an alarm
   fires.
4. **Ephemeral compartments:** for risky reading (e.g., triaging
   untrusted issues), start from a fresh clone and throw it away, so
   nothing planted survives.

## Modes: pick two of three per compartment

Instead of one policy that's both permissive and safe, give each
compartment a mode that breaks one leg of the trifecta. Today's
`~/projects` versus `~/sensitive` split is a start; more modes could
replace special cases:

| Mode | Private data | Untrusted input | Talks out | Use for |
|---|---|---|---|---|
| Ordinary (today's `~/projects`) | its project | the web | GET to the web, POST to a list | most work, especially public projects |
| Sensitive (today's `~/sensitive`) | its project | limited | short allowlist only | private code |
| Research | nothing private | the web | broad, including POST | searching and reading; results go out through the outbox |
| Offline | its project | only what's in it | local engine only | the most sensitive work, on the secure VM |

A research compartment can be quite permissive, since there's nothing
in it worth stealing; I'd copy its results into a working compartment
myself (through its inbox), which keeps me in the loop on what
crosses. That's the "dual agent" idea done with directories instead
of harness features.

A per-session switch (e.g., `compart --mode research claude`) is an
alternative to choosing by directory; either way, the log should
record the mode.

## Simplifying what's built

Here's each current mechanism, the requirement it serves, and whether
I think we could simplify it under these requirements. These are
suggestions to discuss, not decisions.

| Mechanism | Serves | Thought |
|---|---|---|
| Secrets on the Mac, approval prompts | H1 | keep; it's the base of everything |
| `anon-access` | H1, H5 | keep; cheap |
| nono phantom tokens | H1 | keep |
| pasta network namespace | H4 | keep; cheap and strong |
| bwrap filesystem view | H2, H3 | keep for now; Landlock alone is a simpler fallback |
| nono Landlock rules | H2, H3 | keep |
| nono proxy host and method rules | S1, S2, H5 | keep, but stop treating method rules as anti-exfiltration; add caps, a summary, and the private-address check |
| git settings check | H3, S4 | keep; it's the one way out of the compartment that runs code |
| dossier (policy, logs, inbox, outbox) | H3, H6 | keep |
| per-compartment weston | H2 (desktop isolation) | simplify (see below) |
| one-way clipboard copy out of weston | D1 | drop or simplify (see below) |
| snapshots | S3 | keep |

### GUI programs, specifically

The desktop-isolation requirement behind weston is real but narrower
than what we built. A Wayland program on GNOME can't read other
windows or log keystrokes; I believe its main risks are the
clipboard (readable when its window has focus) and the session D-Bus
and portals (which reach much more). Options, simplest first:

1. **No GUI in compartments.** GUI agents (e.g., goose desktop) get
   their own VM, where the VM is the boundary.
2. **Direct Wayland, no D-Bus:** give the compartment your desktop's
   Wayland socket, but not the session bus or portals. It can then read
   the clipboard while focused, and set it any time (as weston's copy
   allows today anyway). No weston, no Xwayland, no copy helper. I
   haven't checked exactly which Wayland protocols mutter offers every
   client, so that needs a look first.
3. **One weston per compartment, no copying (what we had before the
   copy work).** Copy out by saving to the outbox.
4. **Today's design:** weston per compartment, plus one-way copying
   through Xwayland and xclip.

I lean toward 2 for ordinary compartments if mutter's protocols check
out, and 3 under `~/sensitive`: under N1, the clipboard while focused
exposes little that the compartment couldn't already leak.

## Open questions to test

1. Does nono's proxy refuse names that resolve to private, loopback,
   or link-local addresses, including after redirects? (H4)
2. Does nono's proxy look up a name *before* checking its policy? If
   so, a refused request still sends its name to DNS, which is an
   exfiltration channel even under `~/sensitive`. (S1)
3. Can an agent use a POST-allowed host with its own credentials
   (e.g., its own key for the model's API)? (H5, S1)
4. Which rate, size, and host-count limits can nono do today, and
   which would we need to ask for upstream? (S1, S2)
5. Which Wayland protocols does mutter give every client? (GUI
   option 2)

## Recommendation (draft)

1. Keep the VMs and the Mac's secrets server unchanged.
2. Adopt the hard requirements above, and test each one in
   `tests/compartment-test.sh`, starting with H4 (open questions 1 and
   2), which I think is our biggest real exposure today.
3. Stop adding prevention mechanisms for exfiltration of a
   compartment's own data (N1); spend that effort on detection
   instead: a session summary first, then caps and canaries.
4. Add modes, starting with a research mode, instead of loosening the
   ordinary policy for each new use case.
5. Simplify the GUI support, as above.
