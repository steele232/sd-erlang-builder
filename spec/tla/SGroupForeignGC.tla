--------------------------- MODULE SGroupForeignGC ---------------------------
(***************************************************************************)
(* Refined hypothesis for deviations O5 and O6 (spec/deviations.yml),      *)
(* from reading global.erl at 0fdfcf28:                                    *)
(*                                                                         *)
(*  - s_group decides membership and tells global asynchronously           *)
(*    (own_s_group_update / init_own_s_groups messages), so global's view  *)
(*    of "my groups" (gview) can lag s_group's (member).                   *)
(*  - every completed sync (handle_cast resolved / resolved_s) is followed *)
(*    by unregister_foreign_names/1, which deletes every name whose group  *)
(*    is not in gview.                                                     *)
(*  - names are not re-sent later.                                         *)
(*                                                                         *)
(* One group G. Node `r` holds a name from the start. Other nodes join G   *)
(* (s_group membership is immediate, global's view catches up via          *)
(* GlobalLearns). Sync(a, b) between two members copies names both ways,  *)
(* then GCs on both sides.                                                 *)
(*                                                                         *)
(* Fix = "none"        : 19.3 as read (expect violation)                   *)
(* Fix = "sync_member" : membership reaches global before any sync         *)
(*                       (synchronous call instead of a message)           *)
(* Fix = "gc_removal"  : GC only on an explicit removal, never after sync  *)
(***************************************************************************)
EXTENDS FiniteSets

CONSTANTS Nodes, r, Fix
ASSUME r \in Nodes

VARIABLES member,    \* s_group's view: nodes that are members of G
          gview,     \* gview[n]: TRUE iff global on n knows n is in G
          tbl,       \* tbl[n]: does n's table hold the name?
          synced     \* set of unordered pairs that completed a sync

vars == <<member, gview, tbl, synced>>

Init ==
    /\ member = {r}
    /\ gview  = [n \in Nodes |-> n = r]
    /\ tbl    = [n \in Nodes |-> n = r]
    /\ synced = {}

\* add_nodes/2 on r: s_group makes n a member at once; global learns later.
Join(n) ==
    /\ n \notin member
    /\ member' = member \cup {n}
    /\ gview'  = IF Fix = "sync_member" THEN [gview EXCEPT ![n] = TRUE] ELSE gview
    /\ UNCHANGED <<tbl, synced>>

GlobalLearns(n) ==
    /\ n \in member
    /\ ~gview[n]
    /\ gview' = [gview EXCEPT ![n] = TRUE]
    /\ UNCHANGED <<member, tbl, synced>>

\* One completed sync between members a and b: exchange, then foreign-name GC.
Sync(a, b) ==
    /\ a \in member /\ b \in member /\ a # b
    /\ {a, b} \notin synced
    /\ LET has == tbl[a] \/ tbl[b]
           keep(n) == IF Fix = "gc_removal" THEN has ELSE has /\ gview[n]
       IN tbl' = [tbl EXCEPT ![a] = keep(a), ![b] = keep(b)]
    /\ synced' = synced \cup {{a, b}}
    /\ UNCHANGED <<member, gview>>

Next ==
    \/ \E n \in Nodes : Join(n)
    \/ \E n \in Nodes : GlobalLearns(n)
    \/ \E a, b \in Nodes : Sync(a, b)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
\* At rest: everyone has joined, global caught up, every pair synced once.
Quiescent ==
    /\ member = Nodes
    /\ \A n \in Nodes : gview[n]
    /\ \A a, b \in Nodes : a # b => {a, b} \in synced

NamespaceConvergence == Quiescent => \A n \in Nodes : tbl[n]
=============================================================================
