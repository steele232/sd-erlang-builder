# SD Erlang kernel port on OTP 29.1.2 (design B)

**Source of truth:** the patch set in `patches/otp29/`, against upstream
`OTP-29.1.2` `lib/kernel`. The pinned image's kernel sources are
byte-identical to that tag.

**Commands:**
- `bin/sd-port-tree` recreates `build/otp29-kernel` (a small git repo: the
  upstream tag plus the patches as commits) for editing. After editing, run
  `git format-patch base..HEAD -o patches/otp29`.
- `bin/sd-build-port` builds `localhost/sd-erlang:29.1.2-sd-kernel`. It
  compiles the patched modules with the image's own compiler and options, and
  replaces their beams in the image's kernel `ebin`.

## Footprint against upstream

| file | change |
|---|---|
| `global_group.erl` | the five seam functions used by `global`/`net_kernel` (`participant/1`, `member/1`, `group_configured/0`, `publish/2`, `get_own_nodes_with_errors/0`) dispatch to `s_group` while it is the topology provider; the stock bodies are unchanged, renamed `*_gg` |
| `global.erl` | R-API-5: on a group member, `register_name/2,3` and `re_register_name/2,3` return `{no, the_node_is_not_free}`, `whereis_name/1` returns `undefined` (so `send/2` exits `badarg`), and `registered_names/0` returns the `{Group, Name}` pairs (19.3). One `persistent_term` read, no call into `s_group` |
| `kernel.erl`, `kernel.app.src`, `Makefile` | start `s_group` after `global_group`; build and list it |
| `s_group.erl` (new) | API, topology provider, group namespaces, partition prevention and merge, `-rsconfig` |

`global`'s sync, locker and partition-prevention code is untouched.

## Patch series

| patch | change | found by |
|---|---|---|
| 0001 | seam, provider, namespaces, R-API-5 | milestone 1 |
| 0002 | POP1 per-group partition prevention, merge | milestone 3 |
| 0003 | `-rsconfig` persists every membership change (R-PERS-1) | milestone 4 |
| 0004 | re-dial hidden links to free nodes | acceptance L1 |
| 0005 | deliberate re-dials are not failures | acceptance |
| 0006 | names of a down node are dropped by liveness | acceptance |
| 0007 | D-1 re-dial is eventual | acceptance |
| 0008 | off-by-default event trace (`-s_group_trace`) | diagnosis |
| 0009 | name operations and merges re-read their partition under the lock | O5 probe |
| 0010 | compiles on OTP 30 (`exit/2` deprecation under `-Werror`) | `bin/sd-port-release-check master` |
| 0011 | the free-namespace re-dial is eventual too | `SGroupVisibility.tla` (a race in 0004) |
| 0012 | D-7 rejoin as claim, D-8 OR-set membership with group incarnations and tombstones, D-9 anti-entropy | decisions D-7 to D-9 |
| 0013 | trace marks operation boundaries (`op_begin`/`op_end`) | trace validation |
| 0014 | 19.3 API parity (`new_s_group/1`, `monitor_nodes/1`, `add_attributes/2`, `remove_attributes/1,2`, `*_external`) and `{via, s_group, {G, Name}}` | API audit |
| 0015 | merges connect before taking the group lock | `bin/sd-pop` x-first order (33 min hang); model `SGroupMergeLock.tla` |
| 0016 | `s_group` in the kernel `Makefile` MODULES (a source build omitted it) | `bin/sd-host-build`; guarded by `bin/sd-port-lint` |

## Membership, rejoin and repair (D-7 to D-9, M1)

- **Membership is an OR-set (D-8).** Each group has an incarnation and a
  state `{Inc, Adds :: #{Node => [Tag]}, Rems :: [Tag]}`: adding a node adds a
  fresh tag, removing it tombstones the tags observed; concurrent add and
  remove resolve add-wins. Deleting a group records a tombstone `{G, Inc}`, so
  a stale record cannot revive it. Static groups (`kernel s_groups`) use
  deterministic tags `{static, G, N}`, so every node derives the same state.
- **`-rsconfig` record.** `s_groups` (19.3 format, still read by 19.3
  tooling) plus `s_group_state` and `s_group_tombstones`. A restarted node
  reads it as a **claim** plus seeds (D-7): it contacts the recorded members
  and the merge resolves; current members win (a removal made while the node
  was down stands, and the node learns it).
- **Anti-entropy (D-9).** Every `s_group_anti_entropy_ms` (kernel parameter,
  default 5000, 0 disables), each member compares a hash of its table and
  membership with a random in-sync peer; a difference triggers a merge.
  Defence in depth: `SGroupLockScope_old_ae` converges even under the pre-0009
  rule. As with `global`'s merge, repair is a union, so an unregister lost to
  a crash can come back.
- **Node failure (M1).** Membership is unchanged; names of the failed node's
  processes are removed (liveness, patch 0006); the node re-meshes with its
  group-mates when it returns. There is no "down" status (D-10).

## Operations

| knob | effect |
|---|---|
| `-rsconfig` | persist memberships to `<node>.config` in the working directory; restart with `-config <node>` |
| `-kernel s_group_anti_entropy_ms N` | anti-entropy period (0: off) |
| `-s_group_trace` | event trace in a bounded ETS ring (read with the internal `s_group:i_log/0`); `test/pop/sd_pop.erl` turns it into a TLA+ replay |

**Trace validation.** With `SD_POP_TRACE=1`, `bin/sd-pop` replays g1's
recorded events (put, delete, in-sync changes, operation boundaries) with TLC
and checks `InSyncAgree` in every state where no operation is in flight. This
is an invariant checked along a real trace, not a refinement proof: it
catches replicas that disagree at rest, not every deviation from the model.

## How topology reaches the kernel

- **Visibility (O2, S3).** A connection is visible iff both ends publish. A
  member publishes only on the members of its groups; a free normal node
  publishes on everyone; a free hidden node on no one (19.3
  `publish_on_nodes`). Before `s_group` has started, the answer comes from the
  `kernel s_groups` configuration.
- **Free namespace (S2).** `group_configured()` is true, so `global` syncs
  only after `{group_nodeup, Node, ConnId}`. `s_group` sends that when both
  ends are free normal nodes (a small `i_is_free` handshake). `participant/1`
  is true for those peers. `connect_all` stays at its default, so `global`
  meshes free nodes transitively, and partition prevention among them is
  stock: `member/1` is false, so cuts stay physical (L5).
- **Leaving / rejoining.** On joining its first group, a node sends
  `{group_nodedown, Peer, ConnId}` for every free peer and tells them to do
  the same (a logical removal; links stay up). On leaving its last group, it
  re-runs the handshake with its visible peers.
- **Group namespaces (S4).** Replicated within a node's partition of the
  group under a group-wide `global:trans` lock. A member that connects late
  is brought in by the merge (R-NS-5, below). Name GC uses monitors over
  existing links.
- **D-1.** After an install, links to fellow members that are hidden (they
  predate the group) are re-dialled, so they come back visible. The same holds
  for the free namespace (patch 0004): a node that becomes free re-dials its
  hidden links to free normal nodes.
- **Partitions of a group (POP1).** Each node keeps, per group, the members
  its replica is in step with (`K[G]`). Name operations lock and multicast
  within `{self} ∪ K[G]`. On losing a fellow member, it sends per-group
  `pop_lost` reports carrying the link incarnation, and receivers drop the
  far end from that group only: no link is cut. A 2 s tick merges connected
  members back under a joint lock, requiring full connectivity, with 19.3's
  conflict resolution.

## Decisions implemented

| | where |
|---|---|
| D-1 / O3 (pre-existing link becomes visible) | `handle_call({mesh, G}, ...)` |
| D-2 / F1 (free-node failure `no`) | stock `global` on free nodes |
| D-3 / D-4 (duplicate group definitions) | `static_groups/1`: refuse to start, or ignore |
| D-6 / GG1 (`global_groups` xor `s_groups`) | `init/1`: refuse to start if both are set; only `global_groups` gives stock behaviour |
| RC1 (`connect_node/1` for libcluster-style tools) | `connect_node/1` |
| POP1 (per-group logical partition prevention + incarnations) | patch 0002: `pop_lost` / `pop_remove`, `leave_partition/3`, link incarnations (`seq`, `heals`) |
| R-NS-1 / U1 (merge of a group's partitions) | patch 0002: `merge_tick/1`, `merge/2`, `resolve/2` (19.3's `random_exit_name` rule; one name per pid) |
| R-PERS-1 (`-rsconfig`) | patch 0003: `persist/1`, written atomically on every membership change; 0012: `persist/3` adds the OR-set state |
| D-7 (rejoin = seeds + claim) | patch 0012: `initial_claims/1`, `merge_request` / `ms_update` / `group_gone` |
| D-8 (incarnations, OR-set, tombstones) | patch 0012: `ms_*`, `join_ms/2`, `drop_group/2` |
| D-9 (anti-entropy) | patch 0012: `ae_timer`, `ae_repair`, `i_hash/1` |
| M1 (node failure) | patch 0006 (liveness cleanup); model `sd_model:node_down_up/2`; L1 `node_down_up` (`SD_PBT_FAILURES=1`) |

## Invariants learned the hard way (each has a regression case)

- A monitor `'DOWN'` with reason `noconnection` is a lost link, not a dead
  process: never propagate it to other replicas
  (`test/corpus/l1-sdk-noconnection.eterm`).
- The provider must give `global` the answer that held for the connection it
  is handling. So `{free_peer, N}` survives `nodedown` and is cleaned up on
  the next check (L5 seq 16: partition prevention did not fire).
- Leave the free namespace before the first link of a new group exists
  (`test/corpus/l1-c4-joinrace.eterm`).
- Nothing started from `s_group:init/1` may depend on processes that start
  after the kernel supervisor's children: `timer:send_interval/2` deadlocked
  boot, so the tick uses `erlang:send_after/3`.
- A hidden link between two nodes that later both become free must be
  re-dialled, or the free namespace never meshes them
  (`test/corpus/l1-sdk-freedhidden.eterm`, found by acceptance L1).
- A re-dial must be retried until it holds, for free nodes as for members;
  a one-shot re-dial loses to a handshake that decided before the install
  (`SGroupVisibility_oneshot_free_redial`, patch 0011).
- Never dial while holding a group lock: a dial across a cut link blocks to
  the setup timeout, and a retrying merge then starves every name operation
  of the group (`SGroupMergeLock_old`, `bin/sd-pop` x-first order, patch 0015).
- A new kernel module must be listed in `lib/kernel/src/Makefile` as well as
  `kernel.app.src`: the images compile changed modules themselves and never
  exercise the Makefile, so only a source build shows the omission
  (`bin/sd-port-lint`, run by `bin/sd-build-port` and the release check; patch 0016).
