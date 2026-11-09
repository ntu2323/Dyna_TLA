---------------------------------- MODULE MC ----------------------------------
(* Model for TLC / the TLA+ Toolbox: 3 servers (f = 1), keys 1 and 2 led by
   servers 1 and 2; server 3 is a pure follower. Workload: a two-partition
   write, a single-partition write on key 1, and a two-partition read.        *)
EXTENDS DYNA

MCWorkload == << [type |-> "W", keys |-> {1, 2}],
                 [type |-> "W", keys |-> {1}],
                 [type |-> "R", keys |-> {1, 2}] >>
MCKeyLeader == <<1, 2>>

(* Larger model for random simulation (-simulate): keys 1 and 2 led by servers
   1 and 3; single-partition writes on two different leaders, a two-partition
   write and a two-partition read.                                            *)
SimWorkload == << [type |-> "W", keys |-> {1}],
                  [type |-> "W", keys |-> {2}],
                  [type |-> "W", keys |-> {1, 2}],
                  [type |-> "R", keys |-> {1, 2}] >>
SimKeyLeader == <<1, 3>>

(* Small targeted models (keys 1, 2 led by servers 1, 3), searched exhaustively.
   GapWorkload: a write on leader 1, then a write on leader 3 that may carry an
   older deadline (late-follower timestamp inversion, design gap 2).
   WaitWorkload: a two-partition write, then a read of key 1 (wait rule D1).   *)
GapWorkload  == << [type |-> "W", keys |-> {1}], [type |-> "W", keys |-> {2}] >>
WaitWorkload == << [type |-> "W", keys |-> {1, 2}], [type |-> "R", keys |-> {1}] >>
(* Recovery models: key 1 led by server 1 (its keys move to server 2 if it
   leaves the view). A write, then a read of the same keys.                  *)
RecWorkload  == << [type |-> "W", keys |-> {1}], [type |-> "R", keys |-> {1}] >>
RecKeyLeader == <<1>>
Rec2Workload == << [type |-> "W", keys |-> {1, 2}], [type |-> "R", keys |-> {1, 2}] >>
(* Scenario 1 (RecWorkload, key 1 led by server 1 = A; B = 2 inherits it):
   the write at t = 1, upgradable only to t' = 3; the read at t = 2; only A
   may fail; no slow path. Narrows the search to the shape of the bug.      *)
Scn1Constraint ==
    /\ cl[1].t \in {0, 1, 3}
    /\ cl[2].t \in {0, 2}
    /\ cl[1].phase # "slow"
    /\ \A s \in {2, 3} : vst[s] \notin {"crashed", "out"}
(* Scenario 1 core, write only: A commits w at t = 1 and fails; recovery must
   not let an upgrade move w to t' = 3 (Agreement: A holds it COMMITTED at 1). *)
Scn1WWorkload == << [type |-> "W", keys |-> {1}] >>
Scn1WConstraint ==
    /\ cl[1].t \in {0, 1, 3}
    /\ cl[1].phase # "slow"
    /\ \A s \in {2, 3} : vst[s] \notin {"crashed", "out"}
    \* Staging (cuts interleavings, keeps the scenario family): view-change
    \* activity only once A has decided/committed w; the client upgrades or
    \* completes only in the new view; clocks stay <= 1 in view 0.
    /\ (\E s \in Servers : vst[s] # "normal") => (ent[1][1].dec \/ ent[1][1].st = "COMMITTED")
    /\ (cl[1].phase = "upg" \/ cdone[1] # 0) => cl[1].v = 1
    /\ \A s \in Servers : (vst[s] = "normal" /\ view[s] = 0) => clock[s] <= 1
(* N = 5 recovery model (keys 1, 2 led by servers 1, 2): a two-partition write
   (primary 1, second leader 2), then a read on each key.                    *)
N5MultiWorkload == << [type |-> "W", keys |-> {1, 2}], [type |-> "R", keys |-> {1}],
                      [type |-> "R", keys |-> {2}] >>
=============================================================================
