---------------------------- MODULE SGroupNames ----------------------------
(***************************************************************************)
(* Asynchronous name replication inside ONE s_group, abstracting SD        *)
(* Erlang 19.3's `global` (lib/kernel/src/global.erl, 0fdfcf28).           *)
(*                                                                         *)
(* The RELEASE operational semantics (D3.3 ch. 4) is synchronous: a        *)
(* registration updates "the" namespace of the group atomically. The       *)
(* implementation instead keeps one name table per node and:               *)
(*                                                                         *)
(*  - per node, a set `known` of group members it has completed a global   *)
(*    sync with (global:get_known_s_group/1);                              *)
(*  - a pairwise sync when two members connect: each side's names are      *)
(*    exchanged and, when the sync completes, each side becomes `known`    *)
(*    to the other;                                                        *)
(*  - registration multicasts to `known` at that instant.                  *)
(*                                                                         *)
(* Hypothesis for deviation O5 (spec/deviations.yml): the exchange         *)
(* carries a snapshot taken when the sync STARTS, while `known` grows      *)
(* only when it FINISHES. A registration in between reaches neither        *)
(* path, and no later sync between that pair occurs, so the name is lost  *)
(* at that member forever.                                                 *)
(*                                                                         *)
(* Fix = "none"     : the hypothesised 19.3 behaviour (expect violation)   *)
(* Fix = "lock"     : registration excluded while any sync of the          *)
(*                    registering node is in flight                        *)
(* Fix = "backfill" : sync completion re-sends the current table instead   *)
(*                    of the start snapshot                                *)
(***************************************************************************)
EXTENDS FiniteSets

CONSTANTS Members,   \* nodes of the s_group (already created)
          Names,     \* names that may be registered
          Fix        \* "none" | "lock" | "backfill"

VARIABLES known,     \* known[n] : members n has completed a sync with
          tbl,       \* tbl[n]   : names in n's table for this group
          phase,     \* phase[<<a,b>>] for a # b: "idle" | "started" | "done"
          snap,      \* snap[<<a,b>>]: a's names as sent to b at sync start
          used       \* names already registered somewhere (uniqueness)

vars == <<known, tbl, phase, snap, used>>

Pairs == {p \in Members \X Members : p[1] # p[2]}

Init ==
    /\ known = [n \in Members |-> {}]
    /\ tbl   = [n \in Members |-> {}]
    /\ phase = [p \in Pairs |-> "idle"]
    /\ snap  = [p \in Pairs |-> {}]
    /\ used  = {}

\* Both directions of a pair start their exchange together (one nodeup).
SyncStart(a, b) ==
    /\ phase[<<a, b>>] = "idle"
    /\ phase' = [phase EXCEPT ![<<a, b>>] = "started", ![<<b, a>>] = "started"]
    /\ snap'  = [snap  EXCEPT ![<<a, b>>] = tbl[a],    ![<<b, a>>] = tbl[b]]
    /\ UNCHANGED <<known, tbl, used>>

SyncFinish(a, b) ==
    /\ phase[<<a, b>>] = "started"
    /\ LET fromA == IF Fix = "backfill" THEN tbl[a] ELSE snap[<<a, b>>]
           fromB == IF Fix = "backfill" THEN tbl[b] ELSE snap[<<b, a>>]
       IN tbl' = [tbl EXCEPT ![a] = @ \cup fromB, ![b] = @ \cup fromA]
    /\ known' = [known EXCEPT ![a] = @ \cup {b}, ![b] = @ \cup {a}]
    /\ phase' = [phase EXCEPT ![<<a, b>>] = "done", ![<<b, a>>] = "done"]
    /\ UNCHANGED <<snap, used>>

SyncInFlight(n) == \E m \in Members \ {n} : phase[<<n, m>>] = "started"

\* global:register_name/4 on a group: multicast to node() and known nodes.
Register(n, x) ==
    /\ x \notin used
    /\ Fix = "lock" => ~SyncInFlight(n)
    /\ used' = used \cup {x}
    /\ tbl'  = [m \in Members |-> IF m = n \/ m \in known[n]
                                  THEN tbl[m] \cup {x} ELSE tbl[m]]
    /\ UNCHANGED <<known, phase, snap>>

Next ==
    \/ \E a, b \in Members : a # b /\ SyncStart(a, b)
    \/ \E a, b \in Members : a # b /\ SyncFinish(a, b)
    \/ \E n \in Members, x \in Names : Register(n, x)

Spec == Init /\ [][Next]_vars /\ WF_vars(\E a, b \in Members : a # b /\ (SyncStart(a, b) \/ SyncFinish(a, b)))

-----------------------------------------------------------------------------
TypeOK ==
    /\ known \in [Members -> SUBSET Members]
    /\ tbl   \in [Members -> SUBSET Names]
    /\ phase \in [Pairs -> {"idle", "started", "done"}]
    /\ used  \subseteq Names

Quiescent == \A p \in Pairs : phase[p] = "done"

\* S4 / M: the group namespace is replicated on all members. At rest, every
\* member's table holds every registered name.
NamespaceConvergence == Quiescent => \A n \in Members : tbl[n] = used

\* Membership knowledge eventually complete (the quiescence probe in sd-pbt).
KnowledgeCompletes == <>(\A n \in Members : known[n] = Members \ {n})
=============================================================================
