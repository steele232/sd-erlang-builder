# What SD Erlang *is*: the RELEASE specification, restated

This is the reference definition the port-verification work is measured against.
It restates the RELEASE project's own specification, with section citations, and
records how the preserved 19.3 implementation relates to it. Source PDFs and
hashes: `manifests/spec-sources.yml`. The source IDs below (`[D3.3]`, `[AST14]`,
`[JPDC16]`, `[TOPLAS17]`) are defined there.

There are three layers, and they must not be confused:

| Layer | Where it is defined | Status |
|---|---|---|
| **S** — design contract | [JPDC16] §3, Tables 1-3; [TOPLAS17] §V.i | informal, normative intent |
| **M** — operational semantics | [D3.3] ch. 4 (restated in [TOPLAS17] Fig. 14-15) | formal, failure-free, synchronous |
| **I** — implementation | `release-project/otp` 19.3-rebased `0fdfcf28` | executable oracle |

RELEASE validated **I against M** with an `eqc_statem` model ([D3.3] ch. 5,
[AST14]). They found bugs on both sides and *accepted* some differences
(section 4 below). "Historically faithful" therefore means **I-equivalent**, with
M as the explanation and S as the tie-breaker when M is silent.

---

## 1. Design contract (S)

From [JPDC16] §3 and [TOPLAS17] §V.i:

- **S1. Partitioning.** An s_group has a name, a list of nodes and a list of
  registered names. A node may belong to many s_groups or to none.
- **S2. Free nodes.** A node in no s_group is a *free* node and behaves exactly
  as in distributed Erlang. Free nodes form the notional group G0. `global`
  functions behave identically on free nodes in distributed Erlang and in SD Erlang.
- **S3. Connectivity.** Connections are **transitive within an s_group and
  non-transitive with all other nodes** ([JPDC16] Table 1). Design principle:
  *"any node can be directly connected to any other node"*. S_groups restrict
  *transitivity and namespace*, not reachability.
- **S4. Namespace.** Names are registered on, and synchronised between, only the
  nodes of the s_group. `register_name/3` succeeds only if the calling node is in
  the group and neither the name nor the pid is already registered there.
- **S5. Leaving.** After `remove_nodes/2`, the removed node unregisters that
  group's names and **keeps its existing connections**. If it is in no other
  group it becomes free: a free hidden node keeps its links, while a free normal
  node also resyncs with the free normal nodes it is connected to ([JPDC16] §3.1.4).
- **S6. Creation.** `new_s_group/1,2` fails if the initiating node is not in the
  node list, or is already in a group with that name. `/1` generates a random
  name (`crypto:strong_rand_bytes(30)`, per [JPDC16]; [D3.3] §3 says UUIDs).
- **S7. Duplicate group names** are not prevented globally. They are made
  *improbable* and *predictable* ([D3.3] ch. 3):
  - Identical duplicate definitions in a launch config are merged.
  - Conflicting definitions that include the current node terminate the node.
  - Conflicting remote definitions are ignored.
  - Directly overlapping same-name groups do not sync and share neither
    connections nor namespace.
- **S8. Recovery.** With `-rsconfig`, each node persists its own s_group
  membership to a config file on every change and reloads it on restart ([D3.3] ch. 2).

## 2. Abstract state (M) — [D3.3] Fig. 4.1

```text
state = (grs, fgs, fhs, nds)
grs : {(s_group_name, {node_id}, namespace)}     s_groups
fgs : {({node_id}, namespace)}                   free normal groups (maximal transitively-connected sets)
fhs : {(node_id, namespace)}                     free hidden groups (one node each)
nds : {(node_id, node_type, connections, gr_names)}
gr_names  = NoGroup | {s_group_name}
namespace = {(name, pid)}      node_type = Normal | Hidden
```

- **State property:** the node ids of `grs`, `fgs` and `fhs` *partition* the
  node ids of `nds`.
- **Assumptions:** (A1) s_group names are unique. (A2) every node id names a
  node. (A3) failures are ignored ([D3.3] §4: "the current semantics ignores failures").
- **Transition form:** `(state, command, ni) → (state', value)`, executed on node `ni`.

## 3. The fifteen operations (M), with 19.3 behaviour (I)

`ni` is the calling node, `s` a group, `n` a name, `p` a pid. "Member" means
`IsSGroupSNode(ni, s, grs)`.

| # | Operation | M: rule ([D3.3] §4.2.1) | I: 19.3 observed / source | Agree? |
|---|---|---|---|---|
| 1 | `register_name(s,n,p)` | member ∧ n∉ns ∧ p∉ns → add, `True`; else `False` | `yes` / `{no, Reason}`; non-member → `{no, cannot_register_in_remote_group}` | values differ, semantics agree |
| 2 | `re_register_name(s,n,p)` | p∉ns → ns − {(n,_)} ∪ {(n,p)}, `True`; else `False` | `yes` / `{no, pid_is_already_registered}` | values differ |
| 3 | `unregister_name(s,n)` | always `True` (removes if present) | `_`; non-member → `{no, cannot_unregister_from_remote_group}` | **accepted divergence** [AST14] §5 |
| 4 | `registered_names(s)` | member → {(s,n)}; else {} | member → local table; **non-member → searches a node of `s` (remote query)** | diverges for non-members |
| 5 | `whereis_name(s,n)` | member → FindName; else `undefined`; **no state change** | local table, then **searches other groups' nodes** (`global_search`, pings ⇒ new links) | **diverges**: side effects and non-member results |
| 6 | `whereis_name(ni',s,n)` | AddConnections(ni, ni'), then FindName on ni' | pings ni' (link), asks its s_group | agree |
| 7 | `send(p,m)` | AddConnections(ni, node(p)); returns p | ordinary `!` | agree |
| 8 | `send(s,n,m)` | whereis_name(s,n) then send | returns pid or **`{badarg,{s,n,m}}`** (M: `undefined`) | **accepted divergence** [AST14] §5 |
| 9 | `send(ni',s,n,m)` | whereis_name(ni',s,n) then send | as 8 | as 8 |
| 10 | `new_s_group(s,nis)` | ni∈nis → add (s,nis,{}), InterConnect(nis), remove nis from free groups; else `Error` | `{ok,s,Nodes}`; ni∉nis → `{error, remote_s_group}`; existing → `{error, s_group_name_is_in_use}` | agree (value shapes differ) |
| 11 | `add_nodes(s,nis)` | member → InterConnect(all), AddSGroup; else `Error` | `{ok,s,NewNodes}` / `{error, node_does_not_belong_to_the_s_group}` | agree; see 5.2 |
| 12 | `delete_s_group(s)` | member → RemoveSGroup from all, NewFreeNodes, `True`; else `False` | `ok` / `{error,_}` | agree (values) |
| 13 | `remove_nodes(s,nis)` | ni∉nis ∧ member → RemoveSGroup(nis), NewFreeNodes, `True`; else `False`. **Connections unchanged.** | `ok`; links persist (logical disconnect only) | **agree** (S5) |
| 14 | `own_nodes()` / `own_nodes(s)` | OwnGroupNis / {ni}∪nis if member else {} | as M | agree |
| 15 | `own_s_groups()` | {(s, nodes)} for member groups; {} if free | as M | agree |

Auxiliary functions (`AddConnections`, `InterConnectNodes`, `AddSGroup`,
`RemoveSGroup`, `RemoveNodes`, `FindName`, `NewFreeNodes`, `AddFreeNormalGroup`,
`MergeFreeNormalGroups`, `OwnGroupNis`, `OutputNs`, `OutputOwnSGroups`) are
transcribed in `spec/model/sd_model.erl`, one function per rule.

## 4. Divergences RELEASE itself recorded

| ID | What | Source | Status in RELEASE |
|---|---|---|---|
| R1 | `send/3` returns `{badarg, Args}` where M says `undefined` | [AST14] §5 | accepted (state equivalent) |
| R2 | `unregister_name/2` can return `{no, cannot_unregister_from_remote_group}` where M says always `True` | [AST14] §5 | accepted |
| R3 | after a group is removed, the actual state matches the abstract state only *eventually*: "after a 60s timeout and an error report" | [D3.3] §5.2 | open, "believed to be node synchronisation" |
| R4 | node expected a `nodeup` that never arrived (sync) | [AST14] §5, [TOPLAS17] | fixed |
| R5 | `remove_nodes` crashed on a list-search mismatch | [AST14] §5, [TOPLAS17] | fixed |
| R6 | M bug: a free normal node was not removed from its free group on joining an s_group | [AST14] §5 | fixed in M |
| R7 | M bug: `gr_names` could hold both `NoGroup` and an s_group name | [AST14] §5 | fixed in M |

Only **9 of the 15** operations were model-tested ([AST14] §4.2, [D3.3] §5.2):
`new_s_group`, `delete_s_group`, `add_nodes`, `remove_nodes`, `register_name`,
`re_register_name`, `unregister_name`, `whereis_name/2`, `send/2`. The original
setup was 14 nodes (12 normal, 2 hidden), 100 test cases per run, and the
command weights in [D3.3] Fig. 5.4 (also in [AST14] Fig. 6, without
`node_down_up`).

## 5. What this project observed in 19.3, classified against S and M

| ID | Observation (repro) | S | M | Classification |
|---|---|---|---|---|
| O1 | `remove_nodes/2` leaves the TCP link up (3-node demo) | conformant (S5) | conformant (cs unchanged) | **by design** |
| O2 | link between nodes sharing no group is **hidden** (not in `nodes()`, no namespace) | conformant (S3 non-transitive) | silent (M has no visibility) | conformant; M under-specifies |
| O3 | a link created *before* two nodes share a group stays hidden after they join one (`add_nodes/2` creates one) | ? | M says nodes are *interconnected*, and visibility isn't modelled | **spec gap**, needs decision |
| O4 | a `whereis_name/2` / `send/3` miss searches other groups and leaves hidden links | diverges from M (pure lookup) | divergent | **I-behaviour beyond M**; fidelity target is I |
| O5 | group name registered before `global` knows the whole group can stay missing on some members forever (`sd_pbt_o5`: 13/50 trials) | violates S4 | violates M | **defect, root cause found**: `resolved_s/6` broadcasts learned names to the *peer's* partition instead of its own (stock `resolved/5` abcasts to `Known`); confirmed by trace and by intervention |
| — | restarted node's pids can equal pre-crash pids | n/a | n/a | OTP 20 property, not SD |
| I1 | `add_nodes(G, [Caller])` returns `{ok, G, []}` with no membership check (`bin/sd-pbt`) | silent | diverges (M: Error) | I-behaviour, value only |
| I2 | `remove_nodes/2` removes the *intersection* with the members and returns `ok` (`bin/sd-pbt`) | silent | diverges (M: False, no change) | I-behaviour, **state** (adapter `sd_pbt_impl`) |
| Q1 | after `new_s_group`, one member's `global` occasionally never syncs with the group (campaigns: 2/20 runs) | violates S4 | violates M | **defect**, cf. RELEASE R4 |
| Q2 | `remove_nodes(g1, [C])` wipes `global`'s knowledge of C in *another* group shared with C (`sd_pbt_q2`: 5/5) | violates S1/S4 | violates M | **defect**, root cause: unconditional `disconnect_nodes` in `remove_nodes_check`; experimental fix 0002: 0/5 |
| O6 | a name registered before `add_nodes/2` can miss a newly added member (campaign: 1/10 runs) | violates S4 | violates M | **defect**, very likely the O5 root cause (not yet trace-confirmed) |
| F1 | on free nodes, a failed `global:register_name/2` returns `{no, Reason}`; stock returns `no` (L5: 2/20 sequences) | violates S2 | n/a | I-behaviour vs stock; port policy undecided |
| N1 | free groups re-form nondeterministically after `delete_s_group/1` (2–3 distinct end states in 3 runs) | silent | M deterministic | I refines M nondeterministically; L2 uses outcome sets |

## 6. Consequences for "correct port"

1. **Fidelity target = I, explained by M.** A port must reproduce I's observable
   behaviour, including R1, R2, O1, O2 and O4, unless a human records an
   intentional change in the deviation register (`spec/deviations.yml`).
2. **Defects are not fidelity targets.** O5 (and R3 if reproduced) are defects. A
   port may *fix* them, but every fix is a registered deviation, with a test that
   shows the old behaviour on 19.3 and the new behaviour on the port.
3. **M is incomplete:** no failures, no asynchrony, no visibility of links, and
   only 9/15 operations were ever tested. Where M is silent, S decides. Where both
   are silent (O3), the question goes to a human and the answer is recorded.
