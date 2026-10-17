# Proposal M1: extend the executable semantics with node failure

Status: **proposal, needs review.** This is an oracle change: it must land in its
own reviewed change, never together with runtime code (handoff guide).

## Why

- D3.3 §4: "for simplicity the current semantics ignores failures".
- But RELEASE's own generator included `node_down_up` at weight 1 (D3.3 Fig. 5.4),
  so they *tested* failures without a semantics for them.
- S8 (D3.3 ch. 2) specifies recovery: `-rsconfig` persists a node's s_group
  membership and reloads it on restart.
- The demos already exercise crash and restart. L1 cannot, because M has no rule.

## Proposed rules (first cut)

Notation as in D3.3 §4. A down node is still in `nds`, marked dead.

**`node_down(ni)`** (environment step, not an API call)
- `ni` loses all connections: `cs_ni := {}`, and `ni` is removed from every
  other node's `cs`.
- Every name whose pid lives on `ni` is removed from every namespace. This
  follows `global`'s monitor-based cleanup and is observed in the demos
  ("gateway's external_ai name table drops the dead worker_pool").
- **Membership is unchanged** in `grs`: s_groups are configuration, not
  liveness. 19.3 behaves this way: survivors' `own_s_groups/0` still list the
  dead node (demo3 step 10, demo15 crash steps).

**`node_up(ni, cfg)`**
- `cfg = static`: `ni`'s memberships are the groups in its launch config that
  contain it, and its connections re-form on demand (seeding is outside M).
- `cfg = rsconfig`: memberships are those recorded at its last membership change
  (S8).
- `cfg = none`: `ni` is free.

## Open questions for the reviewer

1. While `ni` is down, are `own_nodes/1` on survivors still expected to include
   `ni`? (19.3: yes.)
2. Are names registered by survivors *for* pids on `ni` (`register_name` with a
   remote pid) removed on `node_down`? (`global`: yes, via monitors.)
3. Does `node_up` with `static` config re-join groups that were *changed
   dynamically* since launch? (19.3 with static config: no, it reads the
   launch config.) This is precisely what `-rsconfig` exists to fix.

## Acceptance

- `sd_model_tests` gains rule tests for the three `cfg` cases.
- `sd_pbt_statem` gains `node_down_up` at weight 1 (D3.3 Fig. 5.4), using the
  harness's existing kill/restart.
- Every new I-vs-M difference becomes a deviation entry before any port uses it.
