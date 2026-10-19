--------------------------- MODULE SGroupLockScope ---------------------------
(***************************************************************************)
(* Kernel port, patch 0009: which partition does a name operation (or a    *)
(* merge) write to, and is that set covered by the group lock?             *)
(*                                                                         *)
(* In-sync sets K[n] (POP1) partition a group. A registration multicasts   *)
(* to its partition {r} ∪ K[r] under the group lock; a merge joins two     *)
(* partitions under one lock and installs the union of their tables.       *)
(* Both are split into a READ step (no lock) and a COMMIT step (atomic:    *)
(* lock, write, unlock), so other operations can run in between.           *)
(*                                                                         *)
(*   Rules = "old"  (patches 0001-0008)                                    *)
(*     register: commit writes to the partition read BEFORE the lock;      *)
(*     merge: commit installs on the union read INSIDE the lock, even      *)
(*            beyond the set it locked.                                    *)
(*   Rules = "new"  (patch 0009)                                           *)
(*     register: re-read the partition inside the lock; if it grew, retry; *)
(*     merge: abort if the union grew beyond the locked set.               *)
(*                                                                         *)
(* Observed failure (O5 probe, 1/20 trials before 0009): a merge brought   *)
(* a member into the registrant's partition between the registrant's read *)
(* and its commit; the member never received the name, all in-sync sets   *)
(* were complete, so nothing ever repaired it.                             *)
(***************************************************************************)
EXTENDS FiniteSets, Naturals

CONSTANTS Rules, MaxOps

Nodes == {"a", "b", "c"}
Names == {"x"}

VARIABLES K,       \* K[n] \subseteq Nodes \ {n}: n's in-sync set
          tbl,     \* tbl[n] \subseteq Names: n's replica of the group table
          reg,     \* reg[n]: [phase |-> "idle"|"read", tgt |-> set, name |-> x]
          mrg,     \* merge in flight: [phase, i, y, u0]
          ops      \* operations started (bound)

vars == <<K, tbl, reg, mrg, ops>>

P(n) == {n} \cup K[n]

\* Start: {a, b} in step, c on its own (a member that connects late).
Init ==
    /\ K   = [n \in Nodes |-> IF n = "c" THEN {} ELSE {"a", "b"} \ {n}]
    /\ tbl = [n \in Nodes |-> {}]
    /\ reg = [n \in Nodes |-> [phase |-> "idle", tgt |-> {}, name |-> "x"]]
    /\ mrg = [phase |-> "idle", i |-> "a", y |-> "a", u0 |-> {}]
    /\ ops = 0

RegRead(r, x) ==
    /\ reg[r].phase = "idle" /\ x \notin tbl[r] /\ ops < MaxOps
    /\ reg' = [reg EXCEPT ![r] = [phase |-> "read", tgt |-> P(r), name |-> x]]
    /\ ops' = ops + 1
    /\ UNCHANGED <<K, tbl, mrg>>

RegCommit(r) ==
    /\ reg[r].phase = "read"
    /\ LET T0 == reg[r].tgt
           x  == reg[r].name
           T  == IF Rules = "old" THEN T0 ELSE P(r)
       IN IF Rules = "new" /\ ~(P(r) \subseteq T0)
          THEN /\ reg' = [reg EXCEPT ![r] = [@ EXCEPT !.phase = "read", !.tgt = P(r)]]   \* retry
               /\ UNCHANGED <<K, tbl, mrg, ops>>
          ELSE /\ tbl' = [n \in Nodes |-> IF n \in T THEN tbl[n] \cup {x} ELSE tbl[n]]
               /\ reg' = [reg EXCEPT ![r] = [@ EXCEPT !.phase = "idle"]]
               /\ UNCHANGED <<K, mrg, ops>>

MergeRead(i, y) ==
    /\ mrg.phase = "idle" /\ y \notin P(i) /\ ops < MaxOps
    /\ mrg' = [phase |-> "read", i |-> i, y |-> y, u0 |-> P(i) \cup P(y)]
    /\ ops' = ops + 1
    /\ UNCHANGED <<K, tbl, reg>>

MergeCommit ==
    /\ mrg.phase = "read"
    /\ LET U == P(mrg.i) \cup P(mrg.y)
           T == tbl[mrg.i] \cup tbl[mrg.y]
       IN IF Rules = "new" /\ ~(U \subseteq mrg.u0)
       THEN /\ mrg' = [mrg EXCEPT !.phase = "idle"]                       \* abort; a later tick retries
            /\ UNCHANGED <<K, tbl, reg, ops>>
       ELSE /\ K'   = [n \in Nodes |-> IF n \in U THEN U \ {n} ELSE K[n]]
            /\ tbl' = [n \in Nodes |-> IF n \in U THEN T ELSE tbl[n]]
            /\ mrg' = [mrg EXCEPT !.phase = "idle"]
            /\ UNCHANGED <<reg, ops>>

Next ==
    \/ \E r \in Nodes, x \in Names : RegRead(r, x)
    \/ \E r \in Nodes : RegCommit(r)
    \/ \E i, y \in Nodes : MergeRead(i, y)
    \/ MergeCommit

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
Quiet == mrg.phase = "idle" /\ \A n \in Nodes : reg[n].phase = "idle"

\* At rest, members in step with each other hold the same table.
InSyncAgree == Quiet => \A n \in Nodes : \A m \in K[n] : tbl[n] = tbl[m]
=============================================================================
