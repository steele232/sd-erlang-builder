# Next rounds (queued 2026-10-20)

Phases 1–3 are done (`progress_reports/2026_10_19_report_07.md`). The next
rounds are hands-on. The open question is **developer ergonomics**, and that
can only be measured by a person writing the code. So each item says what
you do and what Claude prepares. Pick in any order. The suggested start is
A1, because it is the instrument for everything else.

Keep one running file, `notes/ergonomics.md`, with one dated line per
friction ("expected X, got Y, lost N minutes"). It is the raw data for the
"developer mental-model changes" row in track B. Each entry also becomes a
USAGE fix or an API proposal.

Example: building the Elixir smoke test, Claude assumed `s_group:connect_node/1`
would work from a free node. It returns `ignored` (RC1). That is correct, but
it surprised the one author who had just ported it.

---

## A. Build things with SD Erlang as it is

| # | what | you | Claude prepares | why it matters |
|---|---|---|---|---|
| A1 | **Playground.** `bin/sd-play` starts N SD nodes in podman from a small topology file. It opens `iex`/`erl` shells on any node, and has `cut a b` / `heal a b` helpers (the `sd-faults` iptables code) | form and break groups by hand; watch `nodes()`, `nodes(hidden)`, names and merges; answer "does this feel like Erlang?" | the script, a 3-group example topology, a one-page cheat sheet | lowest-friction way to *feel* the semantics; the instrument for A2–A5 and B |
| A2 | **Topology dashboard** (Phoenix LiveView on `sd-elixir`): live graph of nodes, groups, visible vs hidden links, names per group, and merge/anti-entropy events (from `-s_group_trace`) | write the LiveView yourself (first real Elixir-on-SD app) | a data endpoint that collects `own_s_groups/0`, `nodes/1`, `erlang:dist_get_stat/1` and trace events; the image | turns the playground into something you can watch; doubles as track B's connection-count meter |
| A3 | **Regional chat / presence** (superseded 2026-10-26 by the WhatsApp-style reference app, `bench/chat/SPEC.md`; libraries in `bench/LIBRARIES.md`). Regions are groups, and a few gateway nodes sit in two regions. Users are GenServers under `{:via, :s_group, ...}`, and cross-region messages go through gateways | write it idiomatically, *then* write the stock `pg` + `global` version and diff | a load generator; a scripted failure schedule | the smallest app with overlapping groups that is useful; a candidate reference app for B |
| A4 | **Orbit** (RELEASE's own distributed hash-table benchmark, the canonical SD Erlang workload) | read the original; port the SD version to the modern API | locate and archive the original source (sha-pinned, as with 19.3) | historical continuity; the most natural reference app for B |
| A5 | **riak_core + s_group.** Groups derived from ring preference lists, an idea the RELEASE report proposed | design session first | survey of riak_core forks that build on OTP 29 | the "strongest demonstration" named in the handoff guide; bigger, do it after A1–A3 |

Possible API work that comes out of A, recorded as `spec/proposals/` entries
before any code:
- membership-change hooks (a known limitation);
- a name-level tombstone, so an unregister made during a partition stays
  unregistered (a known limitation);
- `connect_node/1` ergonomics.

Each is a **new spec question**, so it gets a decision in `spec/DECISIONS.md`
first.

## B. Partisan comparison (the experiment from the handoff guide)

Same application, same topology, same workload and same failure schedule, in
three implementations:
- **A:** stock OTP 29.1.2 with `pg` and libcluster;
- **B:** Partisan;
- **C:** this port.

| # | what | you | Claude prepares |
|---|---|---|---|
| B0 | **Partisan builds on our runtimes.** Partisan 6.0 states OTP 27–29 support, and it generates `partisan_gen_server` etc. from the *installed* OTP sources. Build it on stock `erlang:29.1.2` and on the SD image, and run its own test suite on both | read the results | podman images `sd-partisan` (stock) and `sd-partisan-sd` (SD kernel), pinned to a hex sha |
| B1 | **Pick the reference app.** A3, A4, or both. Rule: the stock version (A) is written first, idiomatically, and B and C are *ports* of it, so "LOC changed" means something | decide; write the stock version | a skeleton repo layout `bench/app/{stock,partisan,sd}` |
| B2 | **Write the ports.** You write at least one of the B/C ports by hand, ideally both, and log every friction in `notes/ergonomics.md` | the ports | review for idiom (each port must be what an expert would write, or the comparison is unfair) |
| B3 | **Harness.** A topology spec (for example 4 groups × 6 nodes + 4 gateways; Partisan uses an equivalent static or HyParView overlay), a workload driver, and the failure schedule reused from `bin/sd-faults` | review the fairness rules before any number is taken | the driver and the collectors |
| B4 | **Measure.** One table per metric (below), raw data committed, and negative results published as-is | interpret; write the conclusion | runs and plots |

Each metric and how it is measured:

| metric | measured by |
|---|---|
| application LOC changed | `git diff --stat` from the stock version to each port |
| distribution-specific abstractions | count of distinct non-OTP modules and calls each port needs (`partisan_*`, `s_group:*`) |
| connection count | per node, `erlang:nodes(connected)` for disterl, plus Partisan's channel sockets (`ss`) |
| memory per node | `erlang:memory(total)` at a steady state |
| control-plane volume | bytes and messages on non-application traffic: dist counters, Partisan stats, iptables byte counters per port |
| failure convergence | time from heal to all replicas agreeing, using the existing convergence checks |
| throughput; p50/p95/p99 latency | driver-side histograms |
| head-of-line effects | p99 of small messages while a large-payload stream shares the same pair (Partisan's channels should win here) |
| operational complexity | config lines plus number of moving parts to deploy, recorded by hand |
| mental-model changes | `notes/ergonomics.md` |

Scale: one Mac with podman tops out around 30–40 small nodes. That is enough
to see *shape*, not to settle scalability. The large-scale run is phase 4,
which stays deferred (it probably needs cloud VMs). State this in every
result.

## C. SD Erlang and Partisan at the same time

This is plausible, because they live at different layers:
- SD Erlang changes native distribution (`net_kernel` visibility,
  `global`'s namespace);
- Partisan, in its default mode, opens its own TCP channels and doesn't
  route messages over disterl.

| # | question | first experiment |
|---|---|---|
| C0 | Do they even coexist? | B0's Partisan test suite on the SD image: on a free node (expected to behave like stock), then on a group member. Watch for Partisan touching `global` (closed on members), and check `connect_disterl`-style options |
| C1 | **Native inside, overlay between.** Tight regions use s_groups (full OTP semantics, PIDs, links, monitors), and only gateways join a Partisan HyParView overlay for cross-region broadcast | A3's chat with cross-region fan-out over Partisan instead of gateway forwarding; compare against pure C |
| C2 | **One membership drives the other.** `s_group:monitor_nodes/1` feeds a Partisan static topology, or Partisan membership callbacks call `s_group:add_nodes/2` | which direction is less glue? This touches the "no membership hooks" limitation, so it's a spec question for D-11 |
| C3 | **Partisan channels for bulk, disterl for control,** between group-mates: avoid head-of-line blocking without leaving native semantics for the control path | the B4 head-of-line test, run on the hybrid |

If C1 or C3 works, it is a fourth column for track B. It may also be the
most practical answer: "use both, at different layers."

## Carry-overs (not hands-on; Claude can do these unattended)

From the handoff guide's MVP checklist, still open:
- TLS distribution on the SD kernel (and a gate layer for it);
- DNS / Kubernetes discovery through `connect_node/1` (libcluster strategy
  check);
- amd64 images (everything so far is arm64);
- SBOM, signing and provenance for `bin/sd-release`, and publishing the
  images (`bin/sd-release VER --images` exists, not yet run);
- periodic `bin/sd-port-release-check` against new OTP releases, recorded in
  `manifests/release-checks.yml`.

## Suggested first session back (about 90 minutes)

1. Claude builds A1 beforehand. You start a 3-group topology, open two
   shells, and register a name on one side.
2. Cut a link, register the same name on both sides, heal, and watch one of
   the two processes die. Read the merge in the trace.
3. Start the ergonomics notes. Pick the reference app for B1.
