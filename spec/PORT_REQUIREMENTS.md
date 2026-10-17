# Requirements for the OTP 29.1.2 port (design B)

Derived from what the 19.3 reference does (`spec/deviations.yml`) and what RELEASE
specified (`SD_ERLANG_SPEC.md`). Every requirement names its source and the test
that checks it.

- **MUST** means fidelity: reproduce 19.3.
- **FIX** means a registered `may_differ` deviation: the port should improve on 19.3.
- **DECIDE** means a human decision is still open.

## API and semantics: reproduce 19.3 (MUST)

| Req | Requirement | Source | Test |
|---|---|---|---|
| R-API-1 | the 15 D3.3 operations with 19.3's argument and return shapes, including `{badarg, _}` from `send/3` and `{no, cannot_unregister_from_remote_group}` | R1, R2 | L1, L2 |
| R-API-2 | `add_nodes(G, [Caller])` → `{ok, G, []}` without a membership check; only already-members → echoes the request | I1, I3 | L1 |
| R-API-3 | `remove_nodes/2` removes the intersection with the members and returns `ok` | I2 | L1 (`sd_pbt_impl`) |
| R-API-4 | a lookup miss (`whereis_name/2`, `send/3`) searches other groups' nodes | O4 | L1, L2 |
| R-TOP-1 | transitive within a group; links between nodes sharing no group are hidden | S3, O2 | demo3, demo15, L2 |
| R-TOP-2 | `remove_nodes/2` keeps existing links | S5, O1 | demo3, L2 |

## Correctness: improve on 19.3 (FIX), each gated by `bin/sd-pbt-ab`

| Req | Requirement | Source | Test that must improve | Fix evidence so far |
|---|---|---|---|---|
| R-NS-1 | after a pairwise sync for group G, each side broadcasts the names it learned to **its own** G-partition, with the peer side as new nodes (stock `resolved/5` semantics, per group). Lock cancellation and in-flight sync handling must follow stock too. Constraint from the O5 trace: receivers add the new nodes to their known set *without* a pairwise exchange, so the broadcast must carry the learned name ops, or force a real exchange | O5, O6 | `sd_pbt_o5` (19.3: 13/50 never converge) | 0001 fixes the repro (0/25) but is rejected by A/B (p = 0.003): partial protocol |
| R-NS-2 | group knowledge completes for every member after membership changes. Concretely: membership changes (new_s_group, add_nodes, remove_nodes) must never logically disconnect a node that still shares another group (one rule covers Q1 and Q2: all five 19.3 call sites) | Q1, Q2 | Q1 trigger replay (19.3: 10/10 fail), L4 `not_quiescent` kinds | 0006 (with 0002): 10/10 pass; A/B pending |
| R-ISO-1 | removing a node from g1 must not disturb `global` knowledge in other groups shared with it | Q2 | `sd_pbt_q2` (19.3: 5/5) | 0002: 0/5, A/B p = 0.29, provisionally accepted |
| R-CRASH-1 | no sync-format confusion between free and s_group peers (C1a); no positional assumptions about peers' group lists (C1b: 19.3 matched the peer's list against its own because `_SGroups` was reused); `global_name_server` must not crash on any peer message | C1 | `c1-seq30` crash rate (19.3: 6/10) + L4 crash-dump capture | 0004: 0/10 interleaved (p = 0.005); regression A/B clean, crash dumps 12 vs 0. **Accepted** |
| R-HID-1 | free nodes never `global`-sync with hidden nodes | H2 | H2 probe | none |
| R-NS-3 | per-group knowledge is never derived from free-partition (`no_group`) knowledge; a node joining a group starts that group's knowledge empty and syncs | Q3 | Q3 trigger replay | 0007 (partial evidence) |
| R-PERS-1 | `-rsconfig` persists **every** membership change, synchronously and atomically | RS1 | `sd_pbt_rsconfig` (19.3: 0/3 at 0 ms) | none |
| R-ATTR-1 | one attribute store, used by both `add_attributes/1` and `choose_nodes/1` | AT1 | `sd_pbt_attrs` | none |

## Open decisions (DECIDE)

| Req | Question | Source |
|---|---|---|
| D-1 | should a link created before two nodes share a group become visible once they do? (19.3: no) | O3 |
| D-2 | free-node `global:register_name/2` failure value: `{no, Reason}` (19.3) or `no` (stock, S2)? | F1 |
| D-3 | conflicting duplicate group in own launch config: merge by union (19.3) or terminate (D3.3)? | DN1 |
| D-4 | conflicting remote duplicates: keep (19.3) or drop (D3.3)? | DN2 |
| D-5 | scope of `prevent_overlapping_partitions` under s_groups (per group, or off for SD nodes) | PORT_OTP29_FEASIBILITY |
| D-6 | can `global_group` and s_groups coexist on one node? | PORT_OTP29_FEASIBILITY |

## Acceptance

`bin/sd-accept <candidate>` plus `bin/sd-pbt-ab <reference> <candidate>`.
- Every MUST row passes on its tests.
- Every FIX row's test improves, with no significant regression in the
  interleaved A/B.
- Every DECIDE row has a recorded decision in `spec/deviations.yml` before release.
