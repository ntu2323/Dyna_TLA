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
=============================================================================
