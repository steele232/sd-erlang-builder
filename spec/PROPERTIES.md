# SD Erlang properties: conformance matrix

Each property is derived from the RELEASE design contract (S, `SD_ERLANG_SPEC.md`
§1) or the semantics (M, §3). For each one: which oracle checks it, and how the
19.3 reference fares. A port is assessed against this table.
**"19.3 status" is the fidelity baseline, not the goal.** Where 19.3 violates a
property, `spec/deviations.yml` says whether a port must reproduce or may fix it.

| ID | Property | From | Oracle(s) | 19.3 status |
|---|---|---|---|---|
| P1 | **Connection safety:** no *visible* link between two nodes that share no s_group (hidden links are allowed) | S3 | demo3 step 3, demo15 "no visible link outside a shared group", L1 C3 (⊆), stock control (fails, as it should) | ✅ holds |
| P2 | **Intra-group transitivity:** members of a group become visibly connected without being told about each other | S3 | demo15 (21 of 35 links formed by SD) | ✅ holds |
| P3 | **Group-scoped namespace:** equal names in different groups are independent; group names are absent from plain `global` | S4 | demo3 step 4, demo15 `worker_pool` ×3, L1 | ✅ holds |
| P4 | **Registration guard:** `register_name/3` succeeds iff caller is a member and neither name nor pid is registered in the group | S4, M | L1 (value + state), demo "cannot register in a group you do not belong to" | ✅ holds |
| P5 | **Namespace convergence:** at rest, every member of a group resolves every name of that group identically | S4, M | L1 C2, demo15 names step, `sd_pbt_o5`, L4 | ❌ **O5** (13/50, root cause found), O6 |
| P6 | **Membership convergence:** at rest, every member agrees on each of its groups' member lists | M | L1 C1 | ✅ holds (no C1-membership failures except during C1 crashes) |
| P7 | **Knowledge convergence:** at rest, `global` on every member knows every other member of each group | implementation of S4 | L1 quiescence probe | ❌ **Q1** (rate drifts), **Q2** (deterministic) |
| P8 | **Group independence:** an operation on group g1 does not change the namespace, membership or knowledge of any other group g2 | S1 | `sd_pbt_q2`, demo15 crash steps | ❌ **Q2** |
| P9 | **Removal semantics:** after `remove_nodes/2` a removed node is no longer a member, cannot register in the group, and keeps its connections | S5, M | demo3 step 8, demo15 move step, L1 | ✅ holds (O1 by design) |
| P10 | **Free-node equivalence:** with no s_group calls, behaviour is identical to stock distributed Erlang of the same base | S2 | L5 (`sd_free_equiv`) | ⚠️ states 20/20 identical; return values differ (**F1**) |
| P11 | **Hidden-node semantics:** hidden nodes are never members of `global` partitions | S2, stock OTP | H2 probe | ❌ **H2** |
| P12 | **Crash isolation:** a crash of node X affects only groups containing X | S1 + reliability goal | demo3 step 10, demo15 crash steps | ✅ holds in scenarios |
| P13 | **No SD-induced crashes:** no sequence of public API calls makes a node's kernel die | reliability goal | L4 campaigns + crash-dump capture | ❌ **C1** (`global.erl:3080`) |
| P14 | **Restart recovery:** with `-rsconfig`, a restarted node regains its last recorded memberships | S8 | `sd_pbt_rsconfig` | ❌ **RS1**: changes within the same second are not persisted (0/3 vs 3/3 with 2 s spacing) |
| P15 | **Duplicate group names:** behave as D3.3 ch. 3 specifies (merge identical, terminate on conflicting own config, ignore conflicting remote) | S7 | none yet | ❓ untested |
| P16 | **Name GC on process death:** a dead registered pid disappears from its group's namespace on every member | S4, `global` | demo3 step 10 (`global:whereis_name` drop) | ✅ holds in scenario |
| P17 | **Attribute selection:** `choose_nodes/1` returns nodes carrying all requested attributes | JPDC'16 §3 | none yet | ❓ untested |

Coverage gaps, in priority order: P15 (duplicate names),
P17 (attributes), and failure semantics in L1 (proposal `spec/proposals/M1-failures.md`).
