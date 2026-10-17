----------------------------- MODULE SGroupMerge -----------------------------
(***************************************************************************)
(* Partition merge in ONE s_group: the O5 root cause (spec/deviations.yml)  *)
(* and the merge procedure a port must implement (PORT_REQUIREMENTS R-NS-1).*)
(*                                                                         *)
(* known[n] is n's global knowledge of the group; nodes that know each     *)
(* other form a partition that shares one name table. Two nodes that do   *)
(* not know each other sync pairwise: they exchange tables, and then each  *)
(* side's partition is told about the merge by a broadcast. RECEIVERS OF   *)
(* THE BROADCAST ADD THE NEW NODES TO known WITHOUT AN EXCHANGE OF THEIR   *)
(* OWN (observed in the O5 high-level trace), so the broadcast must carry  *)
(* the names.                                                              *)
(*                                                                         *)
(* Mode = "sd193": each side informs the PEER's partition about ITSELF,    *)
(*                carrying the names it LEARNED from the peer (19.3        *)
(*                global:resolved_s/6 -> new_nodes_f over HisCmnKnown).    *)
(* Mode = "stock": each side informs ITS OWN partition about the whole     *)
(*                peer partition, carrying the learned names (stock        *)
(*                global:resolved/5 abcast to Known).                      *)
(*                                                                         *)
(* Registration multicasts to the registrant's partition under a lock on   *)
(* it; a sync locks both partitions (stock locker semantics).              *)
(***************************************************************************)
EXTENDS FiniteSets

CONSTANTS Nodes, Names, Mode

VARIABLES known,   \* known[n] \subseteq Nodes \ {n}
          tbl,     \* tbl[n] \subseteq Names
          locked,  \* nodes currently locked
          snap,    \* snap[<<a,b>>]: a's table at sync start
          busy,    \* set of ordered pairs with a sync in flight (both orders)
          used

vars == <<known, tbl, locked, snap, busy, used>>

Part(n) == {n} \cup known[n]

Init ==
    /\ known  = [n \in Nodes |-> {}]
    /\ tbl    = [n \in Nodes |-> {}]
    /\ locked = {}
    /\ snap   = [p \in Nodes \X Nodes |-> {}]
    /\ busy   = {}
    /\ used   = {}

SyncStart(a, b) ==
    /\ a # b /\ b \notin known[a]
    /\ (Part(a) \cup Part(b)) \cap locked = {}
    /\ locked' = locked \cup Part(a) \cup Part(b)
    /\ snap'   = [snap EXCEPT ![<<a, b>>] = tbl[a], ![<<b, a>>] = tbl[b]]
    /\ busy'   = busy \cup {<<a, b>>, <<b, a>>}
    /\ UNCHANGED <<known, tbl, used>>

SyncFinish(a, b) ==
    /\ <<a, b>> \in busy
    /\ LET Pa == Part(a)
           Pb == Part(b)
           la == snap[<<b, a>>]     \* names a learned from b
           lb == snap[<<a, b>>]     \* names b learned from a
       IN
       IF Mode = "stock"
       THEN /\ known' = [n \in Nodes |->
                           IF n \in Pa THEN (known[n] \cup Pb) \ {n}
                           ELSE IF n \in Pb THEN (known[n] \cup Pa) \ {n}
                           ELSE known[n]]
            /\ tbl' = [n \in Nodes |->
                           IF n \in Pa THEN tbl[n] \cup la
                           ELSE IF n \in Pb THEN tbl[n] \cup lb
                           ELSE tbl[n]]
       ELSE \* sd193: a and b exchange; each informs the PEER's partition
            \* about itself, with the names it learned from that very peer.
            /\ known' = [n \in Nodes |->
                           IF n = a THEN known[a] \cup {b}
                           ELSE IF n = b THEN known[b] \cup {a}
                           ELSE IF n \in known[b] THEN known[n] \cup {a}
                           ELSE IF n \in known[a] THEN known[n] \cup {b}
                           ELSE known[n]]
            /\ tbl' = [n \in Nodes |->
                           IF n = a THEN tbl[a] \cup la
                           ELSE IF n = b THEN tbl[b] \cup lb
                           ELSE IF n \in known[b] THEN tbl[n] \cup la
                           ELSE IF n \in known[a] THEN tbl[n] \cup lb
                           ELSE tbl[n]]
    /\ locked' = locked \ (Part(a) \cup Part(b))
    /\ busy'   = busy \ {<<a, b>>, <<b, a>>}
    /\ UNCHANGED <<snap, used>>

Register(n, x) ==
    /\ x \notin used
    /\ Part(n) \cap locked = {}
    /\ used' = used \cup {x}
    /\ tbl'  = [m \in Nodes |-> IF m \in Part(n) THEN tbl[m] \cup {x} ELSE tbl[m]]
    /\ UNCHANGED <<known, locked, snap, busy>>

Next ==
    \/ \E a, b \in Nodes : SyncStart(a, b)
    \/ \E a, b \in Nodes : SyncFinish(a, b)
    \/ \E n \in Nodes, x \in Names : Register(n, x)

Spec == Init /\ [][Next]_vars
        /\ WF_vars(\E a, b \in Nodes : SyncStart(a, b) \/ SyncFinish(a, b))

-----------------------------------------------------------------------------
Symmetric == \A a, b \in Nodes : (b \in known[a]) <=> (a \in known[b])

AllKnown  == \A n \in Nodes : known[n] = Nodes \ {n}

Quiescent == AllKnown /\ busy = {}

\* P5: at rest, every member holds every registered name.
NamespaceConvergence == Quiescent => \A n \in Nodes : tbl[n] = used

\* Partition invariant behind stock global: nodes that know each other share
\* a table (outside in-flight syncs).
PartitionTables == busy = {} => \A a \in Nodes : \A b \in known[a] : tbl[a] = tbl[b]

\* P7 liveness: knowledge eventually completes.
KnowledgeCompletes == <>AllKnown
=============================================================================
