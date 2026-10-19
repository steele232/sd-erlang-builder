# TLA+ models (verification layer L6)

`SGroupNames.tla` models asynchronous name replication within one s_group, a
detail the RELEASE semantics (D3.3 ch. 4) abstracts away. It encodes the
mechanism hypothesised for deviation **O5**: a pairwise `global` sync exchanges
a snapshot taken at sync *start*, while `known` grows at sync *finish*, so a
registration multicast in between misses the peer forever.

| config | models | expected | result (`bin/sd-tla`) |
|---|---|---|---|
| `SGroupNames_none.cfg` | hypothesised 19.3 behaviour | `NamespaceConvergence` violated | violated (7-state trace: register on n1 while n1↔n3 sync is in flight) |
| `SGroupNames_lock.cfg` | registration excluded during the registrant's in-flight syncs | pass | pass, 2,202 distinct states |
| `SGroupNames_backfill.cfg` | sync completion sends the *current* table | pass | pass, 4,974 distinct states |

`SGroupForeignGC.tla` models the **refined hypothesis**, from reading
`global.erl` (0fdfcf28) after the lock analysis ruled out the snapshot window
for 19.3. `s_group` tells `global` about membership asynchronously
(`own_s_group_update`), and every completed sync runs
`unregister_foreign_names/1`, which deletes names of groups not yet in `global`'s
view. A node whose `global` lags therefore deletes freshly received group names,
and they are never re-sent. This would explain **both O5 and O6**.

| config | models | expected | result |
|---|---|---|---|
| `SGroupForeignGC_none.cfg` | 19.3 as read | violated | violated (63 distinct states) |
| `SGroupForeignGC_sync_member.cfg` | membership reaches `global` before any sync | pass | pass (15) |
| `SGroupForeignGC_gc_removal.cfg` | GC only on explicit removal | pass | pass (49) |

Runtime test of the prediction: `sd_pbt_o5:run/2` snapshots, at registration
time, which members' `global:own_s_groups/0` lacks the group.

**Result: refuted for O5.** In 0/6 and 0/7 never-converged trials was any member
lagging, and the registrant's `known(g3)` was complete at the end. The model
remains a valid demonstration of *a* failure mode and its fixes, but it is not
O5's cause. See the `mechanism_investigation` entry in `spec/deviations.yml`.
The open hypothesis is partition merge with representative exchange.

Scope and honesty:
- 3 members and 2 names. The group already exists. There are no failures and no
  membership changes.
- The model reproduces the *shape* of O5, and is consistent with the measured
  15% never-converge rate and with "fine before any sync or after all syncs".
  It has **not** yet been tied line-by-line to `global.erl` (0fdfcf28). Partial
  reading: registration (`trans_s_group` → `set_lock_s_group`) and the sync
  locker (`lock_nodes_safely`) both take the `?GLOBAL_RID` lock, which includes
  the registrant. So the window cannot be "during the locked exchange". It must
  lie between lock release and the `known` update (`resolved/6`,
  `add_to_known`). Next step: trace `global_name_server`/locker messages on the
  registrant during `sd_pbt_o5` trials and refine the model's `SyncFinish` into
  separate unlock/known steps.
- Both fixes keep `KnowledgeCompletes` (liveness) under weak fairness of sync steps.

## `SGroupMerge.tla`: the confirmed O5 mechanism and the port's merge procedure

Models partition merge within one group. Nodes that don't know each other sync
pairwise; each side's partition is then informed by a broadcast whose receivers
add the new nodes to `known` **without** an exchange of their own (as seen in the
O5 high-level trace, `test-results/pbt/o5-trace.bin`).

| config | mode | invariants | result |
|---|---|---|---|
| `SGroupMerge_none.cfg` | `sd193`: inform the *peer's* partition about *yourself*, with names learned *from that peer* (19.3 `resolved_s/6`) | Symmetric, NamespaceConvergence, PartitionTables | violated (first: Symmetric; asymmetric knowledge, a candidate mechanism for **Q1**) |
| `SGroupMerge_ns_none.cfg` | `sd193` | NamespaceConvergence | **violated**: lone registrant n4 syncs with n1 of partition {n1,n2,n3}; n2, n3 learn n4 but never get the name. Two holders at the end, **the same shape as every failing runtime trial** |
| `SGroupMerge_stock.cfg` | `stock`: inform *your own* partition about the whole peer partition, with the learned names; lock both partitions | all three + `<>AllKnown` | **pass** (785 distinct states) |

This is the executable specification for port requirement R-NS-1. Unlike
`SGroupNames` and `SGroupForeignGC` (hypotheses refuted at runtime), this model
reproduces the observed failure.

## `SGroupPOP.tla`: decision D-5, partition prevention under overlapping groups

Models 29.1.2's `prevent_overlapping_partitions` exactly as `global.erl`
documents it: a node that loses a link multicasts `lost_connection`, and
receivers cut the reported node. Four scopings are compared against it. The
topologies are 5 nodes and 3 groups, as a `chain` or a gateway `star`, with
up to 2 link failures. Invariants are checked at rest:
- **OverlapFree:** per-group knowledge is transitive.
- **Collateral:** groups not containing a failed link are untouched.
- **KnowsOnlyLinked.**

| config | policy | result |
|---|---|---|
| `SGroupPOP_stock_overlap.cfg` | stock | OverlapFree **violated**: stock assumes a full mesh; a receiver not linked to the failed node ignores the report |
| `SGroupPOP_stock_collateral.cfg` | stock | Collateral **violated** (matches UD1 at runtime) |
| `SGroupPOP_phys_overlap.cfg` / `_phys_collateral.cfg` | per-group physical cut | both **violated**: one link carries several groups |
| `SGroupPOP_cascade_overlap.cfg` / `_cascade_collateral.cfg` | per-group physical cut + cascade | OverlapFree passes, Collateral **violated** |
| `SGroupPOP_logical_chain.cfg` / `_logical_star.cfg` | per-group logical removal, links stay up | **all pass** |

Not modelled yet: healing and re-sync, and hidden nodes.

## `SGroupPOPHeal.tla`: D-5/POP1 with healing

Adds `Heal`: a failed link comes back, and both ends re-sync each group it
carries. A sync is a partition *merge*, as in `global`: it succeeds only if
every pair across the two partitions is linked. (A first version without
that produced a false counterexample.)

| config | result |
|---|---|
| `SGroupPOPHeal_logical_chain_OverlapFree.cfg` / `_HealedComplete.cfg` | **violated**: a `lost_connection` report still in flight when the heal's syncs land removes the node again |
| `SGroupPOPHeal_logical_epoch_{chain,star}_{OverlapFree,HealedComplete}.cfg` | pass: reports carry the link incarnation, and a receiver ignores reports older than a heal it has processed |

With 2 failures: plain `logical` is violated (135k states). `logical_epoch`
was stopped at 22.6M distinct states without a violation: incomplete.


## Connection-layer models (hardening phase)

Each model has a rule switch: the rule *before* a kernel fix must reproduce
the defect that fix addressed (`EXPECT: violation` configs), and the current
rule must pass. That validates every model against a bug that actually
happened, rather than trusting it.

| model | what it captures | old rule reproduces | current rule |
|---|---|---|---|
| `SGroupLockScope.tla` | name operations and merges vs the group lock's scope | 0009: a registration writes to the partition it read before the lock, and a merge in between leaves a member without the name (`_old`) | pass (`_new`) |
| `SGroupNameGC.tla` | names of processes on a node that crashes, restarts (incarnations) or is re-dialled; asynchronous `nodedown`/`DOWN` | the milestone-1 `noconnection` broadcast loses a live name (`_ncbroadcast`); pre-0005 local delete on `nodedown` diverges replicas (`_nodedown`); the first 0006 attempt keeps a dead pid (`_deferred`) | liveness-based, propagated cleanup: Agree, NoLiveLost, NoDeadKept all hold (`_liveness`) |
| `SGroupVisibility.tla` | visibility fixed at handshake; install ordering; D-1 re-dials | pre-0007 one-shot member re-dial (`_oneshot_mesh`); pre-0004 no free re-dial (`_no_free_redial`); **0004's one-shot free re-dial, found by this model** (`_oneshot_free_redial`, fixed in 0011) | both re-dials eventual (`_current`) |

Not modellable here: the boot deadlock (an OTP startup-ordering fact, caught
by the image build). The join race (`l1-c4-joinrace`) concerns the
implementation's transient links vs the abstract model's connection set, and
is covered by L1's C4 check and its regression replay.
| `SGroupMembership.tla` | D-7 + D-8, before implementation: partitions, crashes, restarts from the record | a version counter loses one side's changes (`_lww`); 19.3-style restart re-asserting its record overrides a removal (`_reassert`) | OR-set membership with records merged as claims (`_orset_claim`) |
