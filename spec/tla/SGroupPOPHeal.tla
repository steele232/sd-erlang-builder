---------------------------- MODULE SGroupPOPHeal ----------------------------
(***************************************************************************)
(* Follow-up to SGroupPOP: the recommended D-5 policy (per-group LOGICAL   *)
(* removal) when failed links come back.                                   *)
(*                                                                         *)
(* Heal: a failed link comes back up; each end re-syncs every group the    *)
(* link carries with that group's members it is linked to. A sync is a     *)
(* partition MERGE, as in global: it succeeds only if every pair across    *)
(* the two partitions is linked; otherwise they stay apart until a later   *)
(* heal triggers another sync.                                             *)
(*                                                                         *)
(* The risk is a Q1-like race: a lost_connection report from the failure   *)
(* is still in flight when the heal's syncs land, and it removes the node  *)
(* again afterwards.                                                       *)
(*   "logical"        no protection                                        *)
(*   "logical_epoch"  each link has an incarnation number; reports carry   *)
(*                    the incarnation that failed, syncs the one that      *)
(*                    healed, and a receiver ignores a report older than a *)
(*                    heal it has already processed (stock global's        *)
(*                    lost_connection carries creation + OpId for the      *)
(*                    analogous purpose)                                   *)
(***************************************************************************)
EXTENDS FiniteSets, Naturals

CONSTANTS Policy, MaxFail, Topo

Nodes == 1..5
GroupIds == {"g1", "g2", "g3"}
\* "small": two groups overlapping in two nodes; node 5 is idle (keeps the
\*          2-failure state space checkable).
GM == IF Topo = "small"
      THEN [g \in GroupIds |-> CASE g = "g1" -> {1, 2, 3}
                                 [] g = "g2" -> {2, 3, 4}
                                 [] g = "g3" -> {5}]
      ELSE IF Topo = "chain"
      THEN [g \in GroupIds |-> CASE g = "g1" -> {1, 2, 3}
                                 [] g = "g2" -> {2, 3, 4}
                                 [] g = "g3" -> {3, 4, 5}]
      ELSE [g \in GroupIds |-> CASE g = "g1" -> {1, 2, 3}
                                 [] g = "g2" -> {1, 4, 5}
                                 [] g = "g3" -> {1, 3, 4}]

Shared(x, y) == {g \in GroupIds : x \in GM[g] /\ y \in GM[g]}
Carried(e) == {g \in GroupIds : e \subseteq GM[g]}   \* groups a link carries
Links0 == {e \in SUBSET Nodes : Cardinality(e) = 2 /\ \E x, y \in e : x # y /\ Shared(x, y) # {}}

VARIABLES link, K, msgs, ep, fails, hseen

vars == <<link, K, msgs, ep, fails, hseen>>

Init ==
    /\ link  = Links0
    /\ K     = [g \in GroupIds |-> [x \in Nodes |-> IF x \in GM[g] THEN GM[g] \ {x} ELSE {}]]
    /\ msgs  = {}
    /\ ep    = [e \in Links0 |-> 0]
    /\ fails = 0
    /\ hseen = [n \in Nodes |-> {}]   \* <<link, incarnation>> heals processed

DropAll(Kn, x, y) ==
    [g \in GroupIds |-> [n \in Nodes |->
        IF n = x THEN Kn[g][n] \ {y} ELSE IF n = y THEN Kn[g][n] \ {x} ELSE Kn[g][n]]]

Lost(x, y, e, i) ==
    UNION {{[kind |-> "lost", to |-> r, a |-> x, b |-> y, g |-> g, e |-> e, i |-> i] :
            r \in K[g][x] \ {y}} : g \in Shared(x, y)}

Fail(a, b) ==
    /\ {a, b} \in link
    /\ fails < MaxFail
    /\ link'  = link \ {{a, b}}
    /\ fails' = fails + 1
    /\ K'     = DropAll(K, a, b)
    /\ msgs'  = msgs \cup Lost(a, b, {a, b}, ep[{a, b}]) \cup Lost(b, a, {a, b}, ep[{a, b}])
    /\ UNCHANGED <<ep, hseen>>

Heal(e) ==
    /\ e \in Links0 \ link
    /\ LET i == ep[e] + 1
           L == link \cup {e}
       IN /\ link'  = L
          /\ ep'    = [ep EXCEPT ![e] = i]
          /\ hseen' = [n \in Nodes |-> IF n \in e THEN hseen[n] \cup {<<e, i>>} ELSE hseen[n]]
          /\ msgs'  = msgs \cup
                      UNION {UNION {{[kind |-> "sync", to |-> r, a |-> p, b |-> p, g |-> g, e |-> e, i |-> i] :
                                     r \in {r \in GM[g] \ {p} : {p, r} \in L}} : g \in Carried(e)} : p \in e}
    /\ UNCHANGED <<K, fails>>

Stale(r, m) == \E h \in hseen[r] : h[1] = m.e /\ h[2] > m.i

Deliver(m) ==
    /\ m \in msgs
    /\ LET r == m.to
           rest == msgs \ {m}
       IN
       IF m.kind = "sync"
       THEN /\ LET P == {m.a} \cup K[m.g][m.a]
                     R == {r} \cup K[m.g][r]
                     U == P \cup R
                 IN IF \A u \in P, w \in R : u = w \/ {u, w} \in link
                    THEN K' = [K EXCEPT ![m.g] = [n \in Nodes |->
                                  IF n \in U THEN K[m.g][n] \cup (U \ {n}) ELSE K[m.g][n]]]
                    ELSE UNCHANGED K
            /\ hseen' = [hseen EXCEPT ![r] = @ \cup {<<m.e, m.i>>}]
            /\ msgs' = rest
       ELSE LET v == IF r = m.b THEN m.a ELSE m.b
            IN /\ IF Policy = "logical_epoch" /\ Stale(r, m)
                  THEN UNCHANGED K
                  ELSE K' = [K EXCEPT ![m.g][r] = @ \ {v}, ![m.g][v] = @ \ {r}]
               /\ msgs' = rest
               /\ UNCHANGED hseen
    /\ UNCHANGED <<link, ep, fails>>

Next ==
    \/ \E a, b \in Nodes : Fail(a, b)
    \/ \E e \in Links0 : Heal(e)
    \/ \E m \in msgs : Deliver(m)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
Quiescent == msgs = {}

OverlapFree ==
    Quiescent =>
      \A g \in GroupIds : \A x, y, z \in GM[g] :
        (x # y /\ y # z /\ x # z /\ y \in K[g][x] /\ z \in K[g][x]) => z \in K[g][y]

\* P7 after recovery: all links back up and nothing in flight => every member
\* knows every other member of each of its groups.
HealedComplete ==
    (Quiescent /\ link = Links0) =>
      \A g \in GroupIds : \A x \in GM[g] : K[g][x] = GM[g] \ {x}
=============================================================================
