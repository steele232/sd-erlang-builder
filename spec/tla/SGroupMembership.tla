--------------------------- MODULE SGroupMembership ---------------------------
(***************************************************************************)
(* Decisions D-7 (rejoin) and D-8 (membership representation), modelled  *)
(* before implementation.                                                  *)
(*                                                                         *)
(* One group; nodes a, b, c start as members. Links can be cut and healed *)
(* (partitions); nodes can crash and restart. Any running member may add  *)
(* or remove a member on its own view; views spread by pairwise merges    *)
(* between connected running nodes.                                        *)
(*                                                                         *)
(*   Merge   = "lww"    version counter, higher version wins, ties broken *)
(*                      by writer (the rejected first version of D-8)     *)
(*             "orset"  observed-remove set: adds carry unique tags, a     *)
(*                      remove tombstones the tags it has seen; merge =    *)
(*                      union (D-8)                                        *)
(*   Restart = "reassert" a restarted node re-adds itself from its record  *)
(*                        (19.3 with a static launch config)              *)
(*             "claim"    its record is merged like any other view, never  *)
(*                        re-asserted (D-7)                                *)
(*                                                                         *)
(* The intended membership comes from the operation log: a node is a      *)
(* member iff some add of it was not removed by a remove that saw that    *)
(* add. Once all running nodes are connected and their views agree, every *)
(* view must show exactly the intended membership (NoLostUpdate).          *)
(***************************************************************************)
EXTENDS FiniteSets, Naturals

CONSTANTS Merge, Restart, MaxOps

Nodes == {"a", "b", "c"}
Pairs == {e \in SUBSET Nodes : Cardinality(e) = 2}

\* A view: orset part (adds: set of <<node, tag>>, rems: set of tags) and an
\* lww part (ver, wr, mem).
Empty == [adds |-> {}, rems |-> {}, ver |-> 0, wr |-> "a", mem |-> {}]

VARIABLES v,       \* v[n]: n's view
          rec,     \* rec[n]: n's persisted record (-rsconfig) = its view when it last changed
          up,      \* running nodes
          con,     \* connected pairs
          addlog,  \* ghost: set of <<node, tag>> ever added
          remlog,  \* ghost: set of tags removed by removes that saw them
          tagc,    \* next tag
          ops

vars == <<v, rec, up, con, addlog, remlog, tagc, ops>>

Members(w) == IF Merge = "orset"
              THEN {x[1] : x \in {a \in w.adds : a[2] \notin w.rems}}
              ELSE w.mem
Intended == {a[1] : a \in {x \in addlog : x[2] \notin remlog}}

Init0 == [adds |-> {<<n, 0>> : n \in Nodes}, rems |-> {}, ver |-> 1, wr |-> "a", mem |-> Nodes]

Init ==
    /\ v = [n \in Nodes |-> Init0]
    /\ rec = [n \in Nodes |-> v[n]]
    /\ up = Nodes /\ con = Pairs
    /\ addlog = {<<n, 0>> : n \in Nodes} /\ remlog = {}
    /\ tagc = 1 /\ ops = 0

Rank(n) == CASE n = "a" -> 1 [] n = "b" -> 2 [] OTHER -> 3

Join(w1, w2) ==
    IF Merge = "orset"
    THEN [w1 EXCEPT !.adds = w1.adds \cup w2.adds, !.rems = w1.rems \cup w2.rems]
    ELSE IF w2.ver > w1.ver \/ (w2.ver = w1.ver /\ Rank(w2.wr) > Rank(w1.wr)) THEN w2 ELSE w1

Add(n, m) ==
    /\ n \in up /\ n \in Members(v[n]) /\ m \notin Members(v[n]) /\ ops < MaxOps
    /\ LET w == v[n]
           w2 == IF Merge = "orset"
                 THEN [w EXCEPT !.adds = @ \cup {<<m, tagc>>}]
                 ELSE [w EXCEPT !.mem = @ \cup {m}, !.ver = @ + 1, !.wr = n]
       IN /\ v' = [v EXCEPT ![n] = w2]
          /\ rec' = [rec EXCEPT ![n] = w2]
    /\ addlog' = addlog \cup {<<m, tagc>>}
    /\ tagc' = tagc + 1 /\ ops' = ops + 1
    /\ UNCHANGED <<up, con, remlog>>

Remove(n, m) ==
    /\ n \in up /\ n # m /\ n \in Members(v[n]) /\ m \in Members(v[n]) /\ ops < MaxOps
    /\ LET w == v[n]
           seen == {a[2] : a \in {x \in w.adds : x[1] = m}}
           w2 == IF Merge = "orset"
                 THEN [w EXCEPT !.rems = @ \cup seen]
                 ELSE [w EXCEPT !.mem = @ \ {m}, !.ver = @ + 1, !.wr = n]
       IN /\ v' = [v EXCEPT ![n] = w2]
          /\ rec' = [rec EXCEPT ![n] = w2]
          /\ remlog' = remlog \cup seen
    /\ ops' = ops + 1
    /\ UNCHANGED <<up, con, addlog, tagc>>

Sync(x, y) ==
    /\ x # y /\ {x, y} \in con /\ x \in up /\ y \in up /\ v[x] # v[y]
    /\ LET w == Join(v[x], v[y]) IN v' = [v EXCEPT ![x] = w, ![y] = w]
    /\ UNCHANGED <<rec, up, con, addlog, remlog, tagc, ops>>

Cut(e) ==
    /\ e \in con /\ ops < MaxOps
    /\ con' = con \ {e} /\ ops' = ops + 1
    /\ UNCHANGED <<v, rec, up, addlog, remlog, tagc>>

Heal(e) ==
    /\ e \notin con
    /\ con' = con \cup {e}
    /\ UNCHANGED <<v, rec, up, addlog, remlog, tagc, ops>>

Crash(n) ==
    /\ n \in up /\ ops < MaxOps
    /\ up' = up \ {n} /\ ops' = ops + 1
    /\ UNCHANGED <<v, rec, con, addlog, remlog, tagc>>

\* Restart from the record. "reassert": the node re-adds itself, as a node
\* reading its launch config does. "claim": the record is just a view.
RestartN(n) ==
    /\ n \notin up
    /\ up' = up \cup {n}
    /\ IF Restart = "reassert" /\ n \in Members(rec[n])
       THEN /\ v' = [v EXCEPT ![n] = IF Merge = "orset"
                                     THEN [rec[n] EXCEPT !.adds = @ \cup {<<n, tagc>>}]
                                     ELSE [rec[n] EXCEPT !.mem = @ \cup {n}, !.ver = @ + 1, !.wr = n]]
            /\ addlog' = addlog \cup {<<n, tagc>>} /\ tagc' = tagc + 1
       ELSE /\ v' = [v EXCEPT ![n] = rec[n]]
            /\ UNCHANGED <<addlog, tagc>>
    /\ UNCHANGED <<rec, con, remlog, ops>>

Next ==
    \/ \E n, m \in Nodes : Add(n, m) \/ Remove(n, m)
    \/ \E x, y \in Nodes : Sync(x, y)
    \/ \E e \in Pairs : Cut(e) \/ Heal(e)
    \/ \E n \in Nodes : Crash(n) \/ RestartN(n)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
Settled == up = Nodes /\ con = Pairs /\ \A x, y \in Nodes : v[x] = v[y]

NoLostUpdate == Settled => \A n \in Nodes : Members(v[n]) = Intended
=============================================================================
