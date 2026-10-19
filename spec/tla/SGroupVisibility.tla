---------------------------- MODULE SGroupVisibility ----------------------------
(***************************************************************************)
(* Kernel port: link visibility (decision D-1, P1/S2; patches 0004, 0007). *)
(*                                                                         *)
(* A connection's visibility is fixed when its handshake completes: it is *)
(* visible iff both ends publish to each other at that moment. A member    *)
(* publishes only on fellow members; a free node publishes on everyone.    *)
(* Changing visibility needs a re-dial (disconnect + new handshake).       *)
(*                                                                         *)
(* A group {a, b} is created; installs reach its members asynchronously   *)
(* and each install connects to the other members; any two nodes may also *)
(* connect for other reasons (messages, rpc); members may leave (free).   *)
(*                                                                         *)
(*   Mesh = "oneshot"   D-1 re-dial runs once, when the installs are done; *)
(*                      links still in their handshake are missed (0007).  *)
(*   Mesh = "eventual"  re-dial on every tick when both ends list each     *)
(*                      other as members (0007).                           *)
(*   FreeRedial = "none"     before 0004: nothing upgrades a hidden link   *)
(*                           between two nodes that are both free;        *)
(*                "oneshot"  0004: re-dial once, when a node becomes free; *)
(*                           a handshake in flight is missed (found by     *)
(*                           this model);                                  *)
(*                "eventual" patch 0011: re-dial on every tick.            *)
(***************************************************************************)
EXTENDS FiniteSets, Naturals

CONSTANTS Mesh, FreeRedial, MaxOps

Nodes == {"a", "b", "c"}
G0 == {"a", "b"}                         \* the group created
G1 == {"b", "c"}                         \* an existing group b is already in
Pairs == {e \in SUBSET Nodes : Cardinality(e) = 2}

VARIABLES mem,    \* mem[n]: members of n's groups as n sees them ({} = free)
          lk,     \* lk[e]: "none" | "hs" (handshake started) | "hsV"/"hsH" (visibility
                  \*        decided, connection not yet listed) | "vis" | "hid"
          pend,   \* members whose install has not run yet
          meshed, \* oneshot mesh already run
          ops

vars == <<mem, lk, pend, meshed, ops>>

Pub(x, y) == mem[x] = {} \/ y \in mem[x]
Co(x, y) == y \in mem[x] /\ x \in mem[y]

Init ==
    /\ mem = [n \in Nodes |-> IF n \in G1 THEN G1 ELSE {}]
    /\ lk = [e \in Pairs |-> "none"]
    /\ pend = G0
    /\ meshed = FALSE
    /\ ops = 0

Install(n) ==
    /\ n \in pend
    /\ mem' = [mem EXCEPT ![n] = @ \cup G0]
    /\ pend' = pend \ {n}
    /\ lk' = [e \in Pairs |-> IF n \in e /\ e \subseteq G0 /\ lk[e] = "none" THEN "hs" ELSE lk[e]]
    /\ UNCHANGED <<meshed, ops>>

\* One-shot D-1 mesh, once all installs are done: re-dial hidden co-member
\* links; a link still in its handshake is not seen as hidden.
OneShotMesh ==
    /\ Mesh = "oneshot" /\ pend = {} /\ ~meshed
    /\ lk' = [e \in Pairs |-> IF e \subseteq G0 /\ lk[e] = "hid" THEN "hs" ELSE lk[e]]
    /\ meshed' = TRUE
    /\ UNCHANGED <<mem, pend, ops>>

EventualMesh(x, y) ==
    /\ Mesh = "eventual" /\ x # y /\ lk[{x, y}] = "hid" /\ Co(x, y)
    /\ lk' = [lk EXCEPT ![{x, y}] = "hs"]
    /\ UNCHANGED <<mem, pend, meshed, ops>>

\* The handshake decides visibility from both ends' publish answers at that
\* moment; only later does the connection show up as visible or hidden.
HsDecide(e) ==
    /\ lk[e] = "hs"
    /\ LET x == CHOOSE n \in e : TRUE
           y == CHOOSE n \in e : n # x
       IN lk' = [lk EXCEPT ![e] = IF Pub(x, y) /\ Pub(y, x) THEN "hsV" ELSE "hsH"]
    /\ UNCHANGED <<mem, pend, meshed, ops>>

HsComplete(e) ==
    /\ lk[e] \in {"hsV", "hsH"}
    /\ lk' = [lk EXCEPT ![e] = IF lk[e] = "hsV" THEN "vis" ELSE "hid"]
    /\ UNCHANGED <<mem, pend, meshed, ops>>

\* Any other traffic between two nodes sets up a connection.
Connect(e) ==
    /\ lk[e] = "none" /\ ops < MaxOps
    /\ lk' = [lk EXCEPT ![e] = "hs"]
    /\ ops' = ops + 1
    /\ UNCHANGED <<mem, pend, meshed>>

\* A member leaves the group (delete_s_group / remove_nodes): it becomes free.
Leave(n) ==
    /\ mem[n] # {} /\ pend = {} /\ ops < MaxOps
    /\ mem' = [m \in Nodes |-> IF m = n THEN {} ELSE IF mem[m] # {} THEN mem[m] \ {n} ELSE mem[m]]
              \* (simplification: leaving drops all of n's groups)
    /\ lk' = IF FreeRedial = "oneshot"
             THEN [e \in Pairs |-> IF n \in e /\ lk[e] = "hid"
                                       /\ \E m \in e \ {n} : mem[m] = {}
                                   THEN "hs" ELSE lk[e]]
             ELSE lk
    /\ ops' = ops + 1
    /\ UNCHANGED <<pend, meshed>>

EventualFree(x, y) ==
    /\ FreeRedial = "eventual" /\ x # y /\ lk[{x, y}] = "hid" /\ mem[x] = {} /\ mem[y] = {}
    /\ lk' = [lk EXCEPT ![{x, y}] = "hs"]
    /\ UNCHANGED <<mem, pend, meshed, ops>>

Next ==
    \/ \E n \in Nodes : Install(n)
    \/ OneShotMesh
    \/ \E x, y \in Nodes : EventualMesh(x, y) \/ EventualFree(x, y)
    \/ \E e \in Pairs : HsDecide(e) \/ HsComplete(e) \/ Connect(e)
    \/ \E n \in Nodes : Leave(n)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
Quiet == pend = {} /\ (Mesh = "oneshot" => meshed) /\ \A e \in Pairs : lk[e] \notin {"hs", "hsV", "hsH"}
         /\ (Mesh = "eventual" => \A x, y \in Nodes : ~(x # y /\ lk[{x, y}] = "hid" /\ Co(x, y)))
         /\ (FreeRedial = "eventual" => \A x, y \in Nodes : ~(x # y /\ lk[{x, y}] = "hid" /\ mem[x] = {} /\ mem[y] = {}))

\* C5 / D-1: fellow members that are connected are visibly connected.
CoMemberVisible == Quiet => \A x, y \in Nodes : x # y /\ Co(x, y) /\ lk[{x, y}] # "none" => lk[{x, y}] = "vis"

\* S2 (with D-1 for the free namespace): free nodes that are connected are visible.
FreeVisible == Quiet => \A x, y \in Nodes : x # y /\ mem[x] = {} /\ mem[y] = {} /\ lk[{x, y}] # "none" => lk[{x, y}] = "vis"
=============================================================================
