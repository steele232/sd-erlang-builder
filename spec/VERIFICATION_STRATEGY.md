# Verifying SD Erlang ports without the original QuickCheck model

**Question:** how do we know a port of SD Erlang to OTP 29.1.2 (or a later
rebase) is *correct*, meaning

- **(A) faithful** to the preserved historical implementation, and
- **(B) conformant** to SD Erlang as RELEASE specified it?

**Answer in one line:** use several independent oracles, each catching what the
others cannot, all tied to one deviation register that a human owns.

```text
                 RELEASE spec (S: design contract, M: semantics)
                         │ transcribed (spec/model/ERRATA.md)
                         ▼
   L0  sd_model ── self-tests (invariants, rule unit tests)
                         │
   L1  PropEr statem: runtime vs sd_model ───────────────► (B) conformance
                         │   value + state mapping only via spec/deviations.yml
                         │
   L2  differential: runtime_port vs runtime_19.3 ───────► (A) fidelity
                         │   same command corpus, observations M can't see
   L3  scenario suites (3-node, 15-node), on both runtimes
   L4  failure profiles (campaigns): defect frequencies, compared statistically
   L5  free-node equivalence: SD vs stock OTP on non-s_group workloads (S2)
   L6  TLA+/TLC: asynchronous protocol model, explains O5/Q1, checks fix designs
   L7  OTP's own suites (kernel/global/distribution) on the port
```

The failure-mode-free semantics M is the RELEASE ground truth, but it is
incomplete: it ignores failures and asynchrony, it doesn't model link
visibility, and only 9 of its 15 operations were ever model-tested. The 19.3
implementation I is what users actually ran, warts included. **Neither alone is
enough.** L1 measures distance to M, L2 measures distance to I, and the register
explains every gap.

---

## L0 — Executable semantics (`spec/model/`)

- `sd_model.erl` transcribes D3.3 ch. 4: the 15 operations plus every auxiliary
  function, one Erlang function per rule.
- `ERRATA.md` lists each interpretation choice (E1–E7).
- `sd_model_tests.erl`: one unit test per rule clause, plus 200 seeded random
  walks of 300 steps checking the D3.3 partition property and the AST'14 §4.5
  invariants (`bin/sd-pbt model`).

**Why it matters:** RELEASE found bugs *in the spec itself* this way (R6, R7).
An oracle you haven't tested is a liability.

## L1 — Model conformance (`bin/sd-pbt`)

`test/pbt/sd_pbt_statem.erl` reconstructs the RELEASE `eqc_statem` setup in
PropEr (D3.3 ch. 5, AST'14 §4):
- 14 nodes: 12 normal, 2 hidden, all free at start.
- Command weights from D3.3 Fig. 5.4.
- Each command runs on its calling node and on `sd_model` in lockstep.
- Postcondition: the returned value and the normalized actual state must match
  the model.

The conformance relation `I ~ M` is defined exactly in `sd_pbt_obs.erl`:
- **C1** membership on every node.
- **C2** namespace on every member: this is the replication check.
- **C3** M's connections ⊆ actual connections.

State is compared as *eventual* equality because I converges asynchronously (R3).

Two modes:

| Mode | Before the next command | Purpose |
|---|---|---|
| `quiescent` (default) | waits until `global` knows every group member | **the oracle**: sequential semantics at rest; races like O5 cannot fire |
| `eager` | conformance only | exposes races (O5); EXPECTED_FAIL on 19.3 |

Return values are mapped onto M-values **only** through registered deviations
(R1, R2, O4, I1). An unregistered difference fails the test. This is what makes
the register the single definition of "allowed".

## L2 — Differential fidelity (port vs 19.3)

L1 can't see what M doesn't model, so a port could match M yet differ from 19.3:
- hidden vs visible links (O2, O3)
- extra links from lookups (O4)
- `registered_names/1` on non-members
- exact error terms

L2 replays **the same command corpus** on both runtimes and compares
observations of everything observable:
- Return values, exactly (after pid normalization).
- `own_s_groups/0`, `own_nodes/0,1`, `s_groups/0` on every node.
- `nodes(visible)` and `nodes(hidden)` restricted to the SUT.
- Per-group name tables on members *and non-members*.

The corpus comes from four places:
1. Every shrunk L1 counterexample.
2. Raw failing sequences from L4 campaigns.
3. A fixed-seed sample of L1-generated sequences.
4. The demo scenario command streams.

Golden observations recorded on 19.3 are stored with hashes, and they are
**read-only to automated patching**, per the handoff guide's rule that an AI
patch never edits its own oracle.

Normalization (guide §Verification): pids → `{pid, Node, Index}`; drop
timestamps and ports; treat orderings as sets wherever the API returns sets.

Nondeterministic observables (O5, Q1) are not compared trace-by-trace. They go to L4.

**Outcome sets (N1).** Some sequences have several legitimate reference
outcomes. Measured self-agreement was 26–28/30 sequences, with sequences 24
and 30 nondeterministic even with a 10 s stability window.

So golden traces are recorded K times on the reference, and
`sd_diff:compare_set/2` accepts a candidate trace if it equals *any* reference
outcome. It also reports how many distinct outcomes each sequence has. The
stability window (3.5 s) must exceed `global`'s locker retry interval (≤ 3 s).

## L3 — Scenario suites

`bin/sd-demo` (3 nodes, 10 checks) and `bin/sd-demo15` (15 nodes, 10 checks,
stock-control 105 vs 35 links) run unchanged on any runtime image. They cover
what generated sequences rarely reach:
- multi-hop gateway routing
- crash plus container restart
- topology-aware discovery
- moving a node between groups

## L4 — Failure profiles (`bin/sd-pbt campaign RUNS N`)

Some 19.3 behaviours are *rare races*:

| ID | Behaviour | Measured on 19.3 |
|---|---|---|
| O5 | name replication race | 3/20 trials never converge in 120 s |
| Q1 | stuck `global` group sync | about 1 in 760 commands |

A campaign runs many independent quickchecks without shrinking, and tallies
failures by kind into a **profile** (`test-results/pbt/profile-*.eterm`).
Acceptance for a port:
- no failure kind absent from the 19.3 profile (new kind = regression);
- for known defects, frequency not worse, by a one-sided Fisher exact test
  at α = 0.05 on equal run counts;
- if a port claims to *fix* a defect (`port_policy: may_differ`), the dedicated
  characterization (`sd_pbt_o5`, …) must show it on both runtimes.

Lessons from applying this to two experimental fixes (`patches/experimental/`):
- **Pool and interleave the reference.** Two 10-run reference campaigns hours
  apart gave 7/10 and 5/10 passing runs. A single reference campaign is not a
  stable baseline: measure the reference in the same session as the candidate,
  and pool reference runs.
- **Campaign counts are censored.** Each run stops at its first failure, so
  failure kinds mask each other. A kind's run-rate is a lower bound, and a
  candidate that removes one kind can raise another's apparent rate. Use more
  runs, or a continue-after-failure mode (not yet built), before rejecting on a
  borderline p.
- **Judge every fix twice.** The targeted repro must improve, and the profile
  must not regress. Fix 0001 passed the first test (O5 0/25 vs 13/50,
  p = 0.003). Its first L4 "regression" (6/10 vs 3/20) was withdrawn once later
  reference campaigns showed 5/10 and 6/9 under newer harness versions.
- **Targeted repros need ≥ 20 replays.** Fix 0009 looked like 9/10 → pass, but
  20 replays gave 10/20 failing vs 7/20 for its baseline. Replay-rate claims
  below n = 20 are anecdotes.
- **Only interleaved A/B counts.** `bin/sd-pbt-ab` alternates single runs on
  reference and candidate, with harness images built once and pinned by ID, so
  drift, load and harness changes affect both arms equally. Interleaved A/B on
  fix 0001: `{not_quiescent,new_s_group}` 1/10 vs 8/10, p = 0.003, rejected.

## L5 — Free-node equivalence with stock OTP

S2 says free nodes behave exactly like distributed Erlang, and this repo already
builds the SD commit's exact upstream parent as a stock image. So any workload
that never calls `s_group` must give identical observations on SD and on stock
OTP of the same base. For the modern port, the reference is stock OTP 29.1.2.
This oracle needs no model at all, and it guards the most common way a kernel
patch breaks users: collateral damage to `global` and `net_kernel`.

## L6 — TLA+ model of the asynchronous protocol (next)

M is synchronous. O5 and Q1 live in what M abstracts away:
- per-node knowledge in `global` (`get_known_s_group`)
- the registration multicast to known nodes only
- the name exchange on connect

The guide's sketch (desired membership, observed membership, connection state as
separate variables) should be extended with per-node `known[n][g]`, per-node name
tables, and in-flight sync messages. TLC can then:
- show that "registration multicasts to `known` only" violates
  `NamespaceConvergence` under quiescence-free schedules (reproducing O5 formally);
- check that a candidate fix (e.g. back-fill on sync completion) restores it
  *before* anyone writes Erlang.

## L7 — OTP regression suites

On the port, run `kernel` `global_SUITE`, `global_group_SUITE` (expected to need
adjustment, since s_group replaces global_group in the kernel supervisor; record
each adjustment as a deviation), `erl_distribution_SUITE` and the
monitor/link suites. The guide's acceptance matrix applies unchanged.

---

## Two reference runtimes

Root-causing 19.3's defects (O5, Q1, Q2, C1) and confirming fixes by
intervention gives a second reference.

| Reference | Image | Used for |
|---|---|---|
| **19.3 as shipped** | `localhost/sd-erlang:19.3-reference` | L2 fidelity traces, L5 baseline. "What users ran" |
| **19.3 + accepted fixes** | `localhost/sd-erlang:19.3-exp-fixed3` (0002 + 0004 + 0006; `patches/experimental/`) | L1/L4 correctness baseline. A port's failure profile must match or beat this one, not 19.3's |

Differences between the two are exactly the `may_differ` entries with
confirmed fixes. A port that reproduces 19.3's *defects* passes L2 but fails
L4 against the fixed reference. That's the intended outcome: faithful in
behaviour, not in bugs.

## What "correct port" means, operationally

A candidate passes when:

1. **L0** passes (the model is unchanged, or its changes were reviewed separately).
2. **L1 quiescent:** ≥ 1,000 cases pass, with no new deviation entries.
3. **L2:** every corpus trace matches the 19.3 golden observations, except
   entries marked `may_differ` and approved.
4. **L3:** both scenario suites pass.
5. **L4:** the profile is no worse than 19.3's.
6. **L5:** free-node workloads are identical to stock OTP of the same base.
7. **L7:** kernel suites pass, with adjustments registered.

Everything a human must decide is in exactly one file: `spec/deviations.yml`.

## Known limits of this approach

- The original D3.3 QuickCheck model is unavailable, so L1 is a
  *reconstruction* and must never be called "the original tests".
- M was only model-tested on 9/15 operations, so our L1 already exceeds RELEASE
  coverage, but it also *defines* expectations RELEASE never checked.
  Disagreements there are findings, not bugs, until triaged.
- `node_down_up` (D3.3 Fig. 5.4, weight 1) is not yet generated, because M
  ignores failures. Adding it requires extending M, which is an oracle change.
- The quiescence probe (`global:get_known_s_group/1`) is 19.3-internal. A port
  must expose an equivalent probe or run L1 in eager mode only.
