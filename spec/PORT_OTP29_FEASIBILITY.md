# Porting SD Erlang to OTP 29.1.2: feasibility and approach

Status: analysis only. No port code exists yet. The handoff guide's rule
applies: **the first modern port is manual**, and automation is designed
afterwards from what that port teaches.

## Inputs (pinned)

| | ref | sha |
|---|---|---|
| SD reference | release-project/otp `19.3-rebased` | `0fdfcf28ab2b6e726edc9c69db71f85f1e0005dd` |
| its base | upstream `master` 2017-03-31 (20.0-rc0) | `5da9e0ab5cb96f2cb37e534b2c1a55c0c2c9783c` |
| target | upstream tag `OTP-29.1.2` | `d199a49a01a2079afb6f2c5c9ae047cd4555e68d` |

Upstream drift, from the SD base to 29.1.2, in the files the SD commit touches
(`git diff --shortstat`):

| file | SD commit changed | base → 29.1.2 | upstream commits |
|---|---|---|---|
| `global.erl` | 1,662 lines (68 hunks) | +1,470 / −346 (2,234 → 3,358 lines) | 48 |
| `net_kernel.erl` | 9 | +2,003 / −608 (1,732 → 3,127) | 118 |
| `kernel.erl` | 22 | +280 / −135 | — |
| `kernel.app.src` | 2 | +61 / −10 | — |
| `global_search.erl` | 144 (SD-specific) | +7 / −4 | — |
| `s_group.erl` | new, 2,664 | n/a | n/a |
| `global_group.erl` (replaced by s_group in the supervisor) | — | +1,042 / −548 | — |

Mechanically re-applying the 19.3 patch is hopeless for `global.erl`: both sides
rewrote the same file. `s_group.erl` and `global_search.erl` are mostly
self-contained and will port with API-level fixes.

## The two semantic seams

SD's `global.erl` changes do two separable jobs:

1. **Topology.** Which nodes `global` syncs with and connects to: transitive
   only within shared s_groups, and non-transitive (hidden) otherwise (S3).
2. **Namespaces.** A name table keyed by `{SGroupName, Name}`, synced per group
   (`exchange_ops_s`, `resolved_s`, `own_s_group_update/remove/delete`,
   `get_known_s_group`, `trans_s_group`).

### What the 19.3 patch adds to `global.erl`

31 new functions, none removed (121 → 152 functions). Grouped by job, this is
the port's feature checklist:

| Job | Functions | Notes for the port |
|---|---|---|
| per-group sync protocol | `handle_node_up_s`, `start_resolver_s`, `resolver_s`, `resolved_s`, `exchange_ops_s_known`, `sync_others_s`, `sync_other_s`, `new_nodes_s`, `new_nodes_f` | parallels upstream's `resolved`/`new_nodes`; upstream rewrote these in OTP 25 |
| per-group knowledge | `get_known_s_group`, `new_known`, `new_known_synced`, `add_node_known_synced`, `known_synced_other_groups`, `combine_known`, `isknown_nodeup`, `added_s_group_nodes`, `check_in_sync`, `node_connected` | the quiescence probe the L1 harness uses |
| per-group lock + registration | `trans_s_group`, `set_lock_s_group`, `lock_on_s_group_nodes` | registration multicasts only to `known` (O5) |
| namespace hygiene | `unregister_foreign_names`, `replace_no_group`, `replace_no_group_s` | `unregister_foreign_names` after every sync + an async membership view = suspected cause of O5/O6 (`spec/tla/SGroupForeignGC.tla`) |
| attributes (`choose_nodes/1`) | `add_attribute`, `remove_attribute`, `registered_attributes` | outside D3.3's 15 operations; not yet covered by any oracle |
| plumbing | `own_s_groups`, `request`, `handle_node_up` | |

### Seam 1 already exists upstream (OTP 25+)

Modern `global` asks `global_group` about topology through a narrow interface:
- `participant/1`, `member/1`, `group_configured/0` and
  `get_own_nodes_with_errors/0` (20 call sites in 29.1.2's `global.erl`);
- `global_group:publish/2`, called from `net_kernel` (line 705).

This was introduced together with **`prevent_overlapping_partitions`** (default
`true` since OTP 25). With it, `global` *actively disconnects* nodes to keep
fully connected partitions, scoped to the global group.

That is the central conflict and the central opportunity:

- SD's overlapping s_groups **are** overlapping partitions, by design. Unscoped
  partition prevention would tear down exactly the topology SD builds.
- But upstream already scopes it to "the group". SD generalizes "one group per
  node" to "a set of overlapping groups". The question becomes: *is each
  s_group, separately, a fully connected partition that `global` maintains?*
  That matches S3 ("transitive within an s_group") and is a far smaller change
  than 19.3's.

### Seam 2 has no upstream equivalent

Modern `global` has one namespace. The per-group namespace is SD's core feature
(S4). It is also where 19.3's defects live: O5, Q1, and RELEASE's own R3/R4.

## Options

| | Approach | Kernel patch surface | Fidelity risk | Notes |
|---|---|---|---|---|
| **A** | Re-port 19.3's `global.erl` changes into 29.1.2's `global.erl` | large (rewrite of a rewritten file) | lowest *if* successful | Inherits O5/Q1 unless fixed; hardest to maintain per OTP release (the guide's automation would fight this file forever) |
| **B** | Topology via a `global_group`-compatible provider (`s_group` implements `participant/member/publish` over overlapping groups); namespaces in a separate per-node server that reuses `global`'s lock + multicall algorithm restricted to group members | small: `kernel.erl` (supervisor child), `net_kernel` publish hook, `global` partition-prevention scoping | medium: name-conflict resolution and sync timing are re-implemented | Smallest diff against upstream; L1/L2 decide whether fidelity holds. Best fit for the guide's "small semantic patch set" goal |
| **C** | Namespaces on top of `pg` scopes, one scope per s_group | smallest | **high**: `pg` has no uniqueness or locking; it is a different semantics from `register_name/3` (S4 "neither Name nor Pid already registered") | Disqualified as a faithful port; at most an alternative design to compare against |

### Option L (library only, no kernel change) is ruled out by measurement

`port/sdx` implements the whole s_group API as a library on stock 29.1.2. It
reaches L3 10/10 (3 and 15 nodes) and L1 100/100, but stock `global` forces a
choice that a library can't escape:

| Kernel setting | S3 / P1: no transitive meshing across groups | S2 / P10: free nodes behave as distributed Erlang (L5 vs stock 29.1.2) |
|---|---|---|
| `connect_all false` | holds (the library meshes members itself) | **1/20**: `global` never syncs under `connect_all false` (29.1.2 `global.erl`: nodeup only records the connection id), so free nodes share no namespace. Upstream documents this: `global` "will not be reliably delivered unless both connect_all and prevent_overlapping_partitions are enabled" |
| `connect_all true` | **violated**: transitive meshing joins groups (L1 C4 caught it in 1/20 cases; the demo15 P1 safety window is the stronger oracle) | **19/20**; the one difference is the winner of a name conflict, decided by pid order (see UD2) |

`connect_all` is read once when `global` starts, so it can't differ per
group. The decision "should `global` sync with / mesh towards this node?" has
to be made per node pair, and that's Seam 1. The kernel hook in design B is
therefore necessary, not just convenient. P18 (stock `global` name API on
members, R-API-5) leads to the same conclusion independently.

**Recommendation: B**, with A as the fallback if L2 shows B can't reach fidelity.
B turns the guide's maintenance problem (rebasing a 3,000-line `global.erl`)
into maintaining a provider against a small, documented upstream interface.

## Decisions a human must make first (from `spec/deviations.yml`)

1. **O3:** should a link created before two nodes share a group become visible
   once they do? 19.3 says no. B would naturally say yes, since publishing is
   evaluated per connection.
2. **O5 / Q1:** fix or reproduce? With option B a fix is nearly free
   (register only once the group's knowledge has settled, or back-fill on sync).
   The deviation register allows `may_differ`.
3. **Partition prevention:** per s_group (recommended), or off for SD nodes?
   This decides whether behaviour under connection loss matches 19.3, where it
   didn't exist at all.
4. **`global_group` coexistence:** 19.3 *replaced* `global_group` in the
   kernel supervisor. A modern port can run either, but mixing global groups
   and s_groups on one node has never been specified.

## How the port gets accepted

`spec/VERIFICATION_STRATEGY.md`. In short, every layer runs unchanged against the
port image:

| Layer | What it checks |
|---|---|
| L0 | model self-tests |
| L1 | PropEr vs M, quiescent mode (needs a quiescence probe: B should export one) |
| L2 | golden traces from 19.3 |
| L3 | the 3- and 15-node scenarios |
| L4 | failure profile no worse than 19.3's |
| L5 | free-node equivalence vs stock 29.1.2 |
| L7 | kernel suites |

Harness portability work already done: `sd_compat.hrl` handles the
`get_stacktrace` removal. The demo and harness otherwise use only APIs present
in both OTP 20 and OTP 29.

## Estimate

Consistent with the guide's 4–8 weeks for the manual port. Under option B, the
`global`-side change is mostly confined to partition-prevention scoping and the
provider calls. The remaining risk sits in the namespace server, where L1/L2
give fast, specific feedback.
