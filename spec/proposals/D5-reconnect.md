# D-5 follow-up: who re-dials after a link loss? Kernel or library (libcluster)?

Context: the user leans toward per-s_group *logical* partition prevention
(`spec/DECISIONS.md` D-5, model `spec/tla/SGroupPOP*.tla`). Recovery after a
link loss then has three parts:

1. **Re-dial:** something re-establishes the lost connection.
2. **Per-group merge:** stock `global`'s merge procedure, scoped to the group
   (R-NS-1, `SGroupMerge.tla` stock mode).
3. **Stale-report protection:** link incarnation numbers, so that a late
   report can't undo a heal (`SGroupPOPHeal.tla`: required even at one
   failure).

Parts 2 and 3 are inside `global`/s_group, so they belong to the kernel port.
This note is about part 1.

## What exists today

| | Re-dials automatically? | Evidence |
|---|---|---|
| Stock OTP 29.1.2 | no; connections are made on demand (send, rpc, `connect_node`, ping) | `global.erl` POP docs describe only the disconnect side |
| SD Erlang 19.3 | **no**: `nodedown` of a group member moves it to `no_contact` (inherited from `global_group`); no timer anywhere in `s_group.erl` | `s_group.erl` `handle_info({nodedown, _})`; `connect_s_group_nodes/1` is called only from new/add/join paths |
| libcluster 3.5.0 (MIT, 2025-01-09) | the basic strategy connects once at startup, and re-dials every `timeout` ms if one is set; Gossip/Kubernetes strategies poll | `lib/strategy/epmd.ex`, README |

So automatic re-dial is **new behaviour relative to 19.3**. A port may add
it (`may_differ`) without losing fidelity in normal operation. It doesn't
*have* to be in the kernel.

## libcluster's extension points (verified in source)

Every topology takes three `{Module, Function, Args}` callbacks (MFAs),
and the node name is appended to the args:
- `connect` (default `{:net_kernel, :connect_node, []}`);
- `disconnect` (default `{:erlang, :disconnect_node, []}`);
- `list_nodes` (default `{:erlang, :nodes, [:connected]}`).

`Cluster.Strategy.connect_nodes/4` treats the result `:ignored` as "not part
of the network", which is logged and not counted as an error.

**Compatibility risk.** With the default `connect`, libcluster would open
*visible* links to every node it discovers, across group boundaries. That
violates P1 (no visible link outside a shared group), and the demo15 P1 step
and L1's C4 would both catch it. So an SD node must never use the default.

## Options

| | What | Kernel change | Pros | Cons |
|---|---|---|---|---|
| **K** | minimal re-dial in s_group: after losing a link to a group member, retry with backoff while membership lasts | small | P2 (members are meshed) is SD's own invariant, and self-healing needs no tooling | new behaviour in the kernel; policy (backoff, limits) is hard-coded |
| **L** | no re-dial in the kernel (as 19.3). Export an SD-aware connect (`s_group:connect_node/1`: connect only if a group is shared, else `ignored`), and ship a small `Cluster.Strategy.SGroups` (list group members via s_group, re-dial on a timer) in a **separate package** | none beyond one exported function | no libcluster fork: it plugs in through the three MFAs; matches 19.3 when unused; policy stays in user space | users must install it to get self-healing |
| **K+L** | K as an off-by-default kernel flag, plus L for discovery | small | either style | two paths to test |

A **fork of libcluster is not needed** for any option. The MFA hooks plus a
custom strategy module cover it. A fork would only be warranted if
libcluster's core assumed one flat cluster in places the hooks don't reach.
Nothing in `strategy.ex` does: it only calls the three MFAs.

## Recommendation (provisional; decide after the kernel port exists)

Start with **L**, as 19.3 does: no re-dial in the kernel, plus the exported
SD-aware connect function, which is useful on its own. Prototype the strategy
against `port/sdx` first; it doesn't need the kernel. Move to K+L only if the
measurements show that relying on user space leaves groups split too long.

Verification hooks:
- an L3 scenario "cut one intra-group link, heal it, expect the group meshed
  again within T". It fails on 19.3 by design (no re-dial), so it's recorded
  as `may_differ`;
- C4/P1 with the strategy running: it must never open a cross-group visible
  link.
