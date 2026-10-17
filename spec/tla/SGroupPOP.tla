------------------------------ MODULE SGroupPOP ------------------------------
(***************************************************************************)
(* Decision D-5 (spec/DECISIONS.md): what should OTP 25+'s                 *)
(* prevent_overlapping_partitions mean under overlapping s_groups?         *)
(*                                                                         *)
(* Stock algorithm (29.1.2 global.erl, "Prevent Overlapping Partitions"):  *)
(* when A loses its connection to B, A multicasts lost_connection(A, B) to *)
(* every node it knows; each receiver R /= B sends remove_connection to B  *)
(* and drops B (R = B drops A instead). Requested removals do not          *)
(* multicast again. Reliable delivery is assumed, so the stock re-forward  *)
(* step is omitted.                                                        *)
(*                                                                         *)
(* One physical link carries every group its two ends share, which is      *)
(* what makes "per s_group" ambiguous. Policies:                           *)
(*   "off"       no reaction                                               *)
(*   "stock"     unscoped, as upstream: receivers are all linked nodes,    *)
(*               the reaction is a physical cut                            *)
(*   "phys"      lost_connection goes only to members of groups that       *)
(*               contain both ends; the reaction is a physical cut          *)
(*   "cascade"   as "phys", and a requested cut is itself reported, scoped *)
(*               to the groups the cut link carried                        *)
(*   "logical"   as "phys", but the reaction drops B from the receiver's   *)
(*               knowledge of THAT group only; links stay up                *)
(*                                                                         *)
(* Knowledge K[g][x] is x's global-partition view of group g (who x shares *)
(* g's namespace with). A lost link removes the pair from every group.     *)
(***************************************************************************)
EXTENDS FiniteSets, Naturals

CONSTANTS Policy, MaxFail, Topo

Nodes == 1..5
GroupIds == {"g1", "g2", "g3"}
\* "chain": each group overlaps the next in two nodes.
\* "star":  node 1 is a gateway in every group (the demo shape), and
\*          g1/g3 and g2/g3 also overlap beyond it.
GM == IF Topo = "chain"
      THEN [g \in GroupIds |-> CASE g = "g1" -> {1, 2, 3}
                                 [] g = "g2" -> {2, 3, 4}
                                 [] g = "g3" -> {3, 4, 5}]
      ELSE [g \in GroupIds |-> CASE g = "g1" -> {1, 2, 3}
                                 [] g = "g2" -> {1, 4, 5}
                                 [] g = "g3" -> {1, 3, 4}]

Shared(x, y) == {g \in GroupIds : x \in GM[g] /\ y \in GM[g]}

VARIABLES link,    \* set of 2-element sets: physical (visible) links
          K,       \* K[g][x] \subseteq GM[g] \ {x}
          msgs,    \* in-flight messages
          failed,  \* links taken down by Fail (the injected faults)
          seen     \* cascade: cuts already reported

vars == <<link, K, msgs, failed, seen>>

Init ==
    /\ link   = {e \in SUBSET Nodes : Cardinality(e) = 2 /\ \E x, y \in e : x # y /\ Shared(x, y) # {}}
    /\ K      = [g \in GroupIds |-> [x \in Nodes |-> IF x \in GM[g] THEN GM[g] \ {x} ELSE {}]]
    /\ msgs   = {}
    /\ failed = {}
    /\ seen   = {}

DropAll(Kn, x, y) ==   \* x and y forget each other in every group
    [g \in GroupIds |-> [n \in Nodes |->
        IF n = x THEN Kn[g][n] \ {y} ELSE IF n = y THEN Kn[g][n] \ {x} ELSE Kn[g][n]]]

\* Reports a lost link x-y from x's side: who x tells, per policy.
Reports(x, y, Gs) ==
    IF Policy = "off" THEN {}
    ELSE IF Policy = "stock"
         THEN {[kind |-> "lost", to |-> r, a |-> x, b |-> y, g |-> "all"] :
               r \in {r \in Nodes \ {x, y} : {x, r} \in link}}
         ELSE UNION {{[kind |-> "lost", to |-> r, a |-> x, b |-> y, g |-> g] :
                      r \in K[g][x] \ {y}} : g \in Gs}

\* An injected fault: the link a-b goes down; both ends see nodedown.
Fail(a, b) ==
    /\ {a, b} \in link
    /\ Cardinality(failed) < MaxFail
    /\ link'   = link \ {{a, b}}
    /\ failed' = failed \cup {{a, b}}
    /\ K'      = DropAll(K, a, b)
    /\ msgs'   = msgs \cup Reports(a, b, Shared(a, b)) \cup Reports(b, a, Shared(a, b))
    /\ UNCHANGED seen

Deliver(m) ==
    /\ m \in msgs
    /\ LET r == m.to
           v == IF r = m.b THEN m.a ELSE m.b     \* who r removes
           rest == msgs \ {m}
       IN
       IF Policy = "logical"
       THEN /\ K' = [K EXCEPT ![m.g][r] = @ \ {v}, ![m.g][v] = @ \ {r}]
            /\ msgs' = rest
            /\ UNCHANGED <<link, seen>>
       ELSE IF {r, v} \notin link
       THEN /\ msgs' = rest
            /\ UNCHANGED <<link, K, seen>>
       ELSE IF Policy = "cascade"
       THEN LET Gs == Shared(r, v)
                key == {r, v}
                new == IF key \in seen THEN {}
                       ELSE UNION {{[kind |-> "lost", to |-> q, a |-> r, b |-> v, g |-> g] :
                                     q \in K[g][r] \ {v}} : g \in Gs} \cup
                            UNION {{[kind |-> "lost", to |-> q, a |-> v, b |-> r, g |-> g] :
                                     q \in K[g][v] \ {r}} : g \in Gs}
            IN /\ link' = link \ {{r, v}}
               /\ K' = DropAll(K, r, v)
               /\ msgs' = rest \cup new
               /\ seen' = seen \cup {key}
       ELSE /\ link' = link \ {{r, v}}
            /\ K' = DropAll(K, r, v)
            /\ msgs' = rest
            /\ UNCHANGED seen
    /\ UNCHANGED failed

Next ==
    \/ \E a, b \in Nodes : Fail(a, b)
    \/ \E m \in msgs : Deliver(m)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
Quiescent == msgs = {}

\* Upstream's goal, per group: at rest, knowledge inside each group is
\* transitive (no overlapping partitions within a group).
OverlapFree ==
    Quiescent =>
      \A g \in GroupIds : \A x, y, z \in GM[g] :
        (x # y /\ y # z /\ x # z /\ y \in K[g][x] /\ z \in K[g][x]) => z \in K[g][y]

\* P8 / P12: a group that does not contain both ends of a failed link is
\* left fully intact.
Collateral ==
    Quiescent =>
      \A g \in GroupIds :
        (\A f \in failed : ~(f \subseteq GM[g])) =>
          \A x \in GM[g] : K[g][x] = GM[g] \ {x}

\* Knowledge never claims a link that is down.
KnowsOnlyLinked == \A g \in GroupIds : \A x \in Nodes : \A y \in K[g][x] : {x, y} \in link
=============================================================================
