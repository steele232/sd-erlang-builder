----------------------------- MODULE SGroupNameGC -----------------------------
(***************************************************************************)
(* Kernel port: when is a group name dropped because its process is gone? *)
(* (spec/deviations.yml P16; patches 0001's noconnection fix, 0005, 0006.) *)
(*                                                                         *)
(* Members m1, m2 (always connected to each other) replicate one name     *)
(* whose process lives on node o, which need not be a member. o crashes   *)
(* and restarts (a new incarnation: the old pid is dead), and links m-o   *)
(* are re-dialled on purpose (decision D-1). Each m learns about the o    *)
(* link only through asynchronous notifications in evq[m]:                 *)
(*   "nd" nodedown, "nc" monitor DOWN noconnection, "dn" monitor DOWN for  *)
(*   a dead process, "chk" a pending liveness check.                       *)
(*                                                                         *)
(* Rules (cleanup policy):                                                 *)
(*   "nc_broadcast"       a DOWN noconnection is treated as death and      *)
(*                        broadcast; nodedown deletes locally (pre-fix)    *)
(*   "delete_on_nodedown" nodedown deletes the name locally (before 0005)  *)
(*   "deferred"           nodedown schedules a check that deletes only if  *)
(*                        o is still unreachable; a DOWN noconnection with *)
(*                        o connected is ignored (first 0006 attempt)      *)
(*   "liveness"           the check deletes dead pids whether or not o is  *)
(*                        back, and propagates; a DOWN noconnection with o *)
(*                        connected means an earlier incarnation, i.e.     *)
(*                        death (current 0006)                             *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS Rules, MaxInc, MaxOps

M == {"m1", "m2"}
None == 99   \* sentinel: no pid (incarnations stay below MaxInc)

VARIABLES upo,   \* o is running
          inc,   \* o's current incarnation
          lnk,   \* lnk[m]: link m-o up
          tbl,   \* tbl[m]: incarnation of the registered pid, or None
          mon,   \* mon[m]: m monitors the pid in its table
          evq,   \* evq[m]: pending notifications at m
          reg,   \* ghost: the registered pid (incarnation) or None
          ops

vars == <<upo, inc, lnk, tbl, mon, evq, reg, ops>>

Alive(p) == p # None /\ upo /\ p = inc

Init ==
    /\ upo = TRUE /\ inc = 0
    /\ lnk = [m \in M |-> TRUE]
    /\ tbl = [m \in M |-> None] /\ mon = [m \in M |-> FALSE]
    /\ evq = [m \in M |-> {}]
    /\ reg = None /\ ops = 0

\* The process on o registers (multicast to both members).
Register ==
    /\ upo /\ ~Alive(reg) /\ ops < MaxOps
    /\ \A m \in M : evq[m] = {}
    /\ tbl' = [m \in M |-> inc] /\ reg' = inc
    /\ mon' = [m \in M |-> lnk[m]]
    /\ ops' = ops + 1
    /\ UNCHANGED <<upo, inc, lnk, evq>>

LinkLost(m) == {"nd"} \cup (IF mon[m] THEN {"nc"} ELSE {})

Crash ==
    /\ upo /\ ops < MaxOps
    /\ upo' = FALSE
    /\ lnk' = [m \in M |-> FALSE]
    /\ evq' = [m \in M |-> IF lnk[m] THEN evq[m] \cup LinkLost(m) ELSE evq[m]]
    /\ mon' = [m \in M |-> FALSE]
    /\ ops' = ops + 1
    /\ UNCHANGED <<inc, tbl, reg>>

\* A fast restart: new incarnation, links back at once; re-monitoring the
\* old pid yields a DOWN for a dead process.
Restart ==
    /\ ~upo /\ inc < MaxInc
    /\ upo' = TRUE /\ inc' = inc + 1
    /\ lnk' = [m \in M |-> TRUE]
    /\ evq' = [m \in M |-> IF tbl[m] # None THEN evq[m] \cup {"dnc"} ELSE evq[m]]
    /\ UNCHANGED <<tbl, mon, reg, ops>>

\* A deliberate re-dial of m's link to o: down and immediately up again.
Redial(m) ==
    /\ upo /\ lnk[m] /\ ops < MaxOps
    /\ evq' = [evq EXCEPT ![m] = @ \cup LinkLost(m)]
    /\ mon' = [mon EXCEPT ![m] = (tbl[m] # None)]     \* re-monitored on nodeup
    /\ ops' = ops + 1
    /\ UNCHANGED <<upo, inc, lnk, tbl, reg>>

DropEverywhere(p) == [m \in M |-> IF tbl[m] = p THEN None ELSE tbl[m]]

Handle(m, e) ==
    /\ e \in evq[m]
    /\ LET rest == [evq EXCEPT ![m] = @ \ {e}]
           p == tbl[m]
       IN
       CASE e = "nc" /\ Rules = "nc_broadcast" ->
                /\ tbl' = DropEverywhere(p) /\ evq' = rest
         [] e = "nd" /\ Rules \in {"nc_broadcast", "delete_on_nodedown"} ->
                /\ tbl' = [tbl EXCEPT ![m] = None] /\ evq' = rest
         [] e = "nd" ->
                /\ evq' = [rest EXCEPT ![m] = @ \cup {"chk"}] /\ UNCHANGED tbl
         [] e = "chk" /\ Rules = "deferred" ->
                /\ tbl' = IF ~lnk[m] THEN [tbl EXCEPT ![m] = None] ELSE tbl
                /\ evq' = rest
         [] e = "chk" /\ Rules = "liveness" ->
                /\ tbl' = IF ~lnk[m] \/ ~Alive(p) THEN DropEverywhere(p) ELSE tbl
                /\ evq' = rest
         \* re-monitor of the pid on a restarted node: DOWN noconnection with o connected
         [] e = "dnc" /\ Rules = "liveness" ->
                /\ tbl' = IF p # None /\ ~Alive(p) THEN DropEverywhere(p) ELSE tbl
                /\ evq' = rest
         [] OTHER ->
                /\ evq' = rest /\ UNCHANGED tbl
    /\ UNCHANGED <<upo, inc, lnk, mon, reg, ops>>

Next ==
    \/ Register \/ Crash \/ Restart
    \/ \E m \in M : Redial(m)
    \/ \E m \in M, e \in {"nd", "nc", "chk", "dnc"} : Handle(m, e)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
Quiet == \A m \in M : evq[m] = {}

Agree == Quiet => tbl["m1"] = tbl["m2"]
NoLiveLost == Quiet => (Alive(reg) => \A m \in M : tbl[m] = reg)
NoDeadKept == Quiet => \A m \in M : tbl[m] # None => Alive(tbl[m])
=============================================================================
