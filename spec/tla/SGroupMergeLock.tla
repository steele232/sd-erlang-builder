--------------------------- MODULE SGroupMergeLock ---------------------------
(***************************************************************************)
(* Kernel port, patch 0015: can a merge that keeps failing starve the name *)
(* operations of its group?                                                *)
(*                                                                         *)
(* While a link inside the group is cut, a member's mesh tick keeps        *)
(* retrying the merge across it. A registration needs the same group lock. *)
(* Lock acquisition is not strongly fair (global:trans retries with        *)
(* backoff), so only weak fairness is assumed: an action that stays        *)
(* enabled eventually happens; one enabled only now and then may not.      *)
(*                                                                         *)
(*   Rules = "old"  (patches 0001-0014)                                    *)
(*     the merge takes the lock, then dials the other side; across the cut *)
(*     the dial blocks until the setup timeout, then the merge releases    *)
(*     and the next tick takes the lock again;                             *)
(*   Rules = "new"  (patch 0015)                                           *)
(*     the merge dials before the lock and takes it only once the links    *)
(*     are up; inside the lock it only checks that they still are.         *)
(*                                                                         *)
(* Observed failure (bin/sd-pop, order split_register_rev, before 0015):   *)
(* the registration on x hung for 33 minutes while the link a-x was cut.   *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS Rules

VARIABLES lock,    \* "free" | "merge" | "reg"
          mph,     \* merge phase: "idle" | "dial" (dialling, with or without the lock)
          rph,     \* registration phase: "want" | "held" | "done"
          cut      \* the link the merge needs is cut

vars == <<lock, mph, rph, cut>>

Init == lock = "free" /\ mph = "idle" /\ rph = "want" /\ cut = TRUE

\* A mesh tick starts a merge attempt.
MergeStart ==
    /\ mph = "idle"
    /\ IF Rules = "old"
       THEN lock = "free" /\ lock' = "merge"
       ELSE UNCHANGED lock
    /\ mph' = "dial"
    /\ UNCHANGED <<rph, cut>>

\* The dial fails at the setup timeout (link cut): release, retry next tick.
MergeDialFails ==
    /\ mph = "dial" /\ cut
    /\ lock' = IF lock = "merge" THEN "free" ELSE lock
    /\ mph' = "idle"
    /\ UNCHANGED <<rph, cut>>

\* Links up: lock (new rule: taken now), install, release.
MergeCommit ==
    /\ mph = "dial" /\ ~cut
    /\ \/ lock = "merge"
       \/ Rules = "new" /\ lock = "free"
    /\ lock' = "free" /\ mph' = "idle"
    /\ UNCHANGED <<rph, cut>>

RegLock   == rph = "want" /\ lock = "free" /\ lock' = "reg" /\ rph' = "held" /\ UNCHANGED <<mph, cut>>
RegCommit == rph = "held" /\ lock' = "free" /\ rph' = "done" /\ UNCHANGED <<mph, cut>>

Next == MergeStart \/ MergeDialFails \/ MergeCommit \/ RegLock \/ RegCommit

\* The cut persists (the scenario registers during the partition).
Spec == Init /\ [][Next]_vars
        /\ WF_vars(MergeStart) /\ WF_vars(MergeDialFails) /\ WF_vars(MergeCommit)
        /\ WF_vars(RegLock) /\ WF_vars(RegCommit)

-----------------------------------------------------------------------------
MutualExclusion == ~(lock = "reg" /\ mph = "dial" /\ Rules = "old")

\* A registration during a partition completes.
RegCompletes == <>(rph = "done")
=============================================================================
