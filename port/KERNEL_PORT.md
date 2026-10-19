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
| `kernel.erl`, `kernel.app.src` | start `s_group` after `global_group` |
| `s_group.erl` (new) | API, topology provider, group namespaces, partition prevention and merge, `-rsconfig` |

`global`'s sync, locker and partition-prevention code is untouched.

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
| R-PERS-1 (`-rsconfig`) | patch 0003: `persist/1`, written atomically on every membership change |

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
