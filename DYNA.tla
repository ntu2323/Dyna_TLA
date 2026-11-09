------------------------------- MODULE DYNA -------------------------------
(***************************************************************************)
(* DYNA: deadline-ordered, multi-partition replication, with recovery.     *)
(*                                                                         *)
(* Source of truth: DYNA/protocols/src/ionia/dyna/dyna_algo_design.txt     *)
(* (as of 2026-11-02), plus these decisions confirmed by the designer:     *)
(*                                                                         *)
(*  D1. WAIT FOR THE DEADLINE. A server may set a txn COMMITTING or        *)
(*      COMMITTED at deadline t, or reply about it, only once its own      *)
(*      clock has reached t -- on every path (Fast/Slow-Commit, leader     *)
(*      sync (TsAgree), Replicate-Commit).                                 *)
(*  D2. SLOW PATH only when every involved leader replied, the leaders     *)
(*      disagree, AND at least f+1 distinct servers (leaders included)     *)
(*      replied. Otherwise (too few replies: the txn was truly late) the   *)
(*      client RECASTS it with a larger deadline.                          *)
(*  D3. RECAST = same txn id, new larger deadline t'. Each server          *)
(*      re-classifies the txn against t' even if it holds it SPECULATIVE   *)
(*      or COMMITTING at the old deadline. A COMMITTED / executed txn is   *)
(*      never touched (the server answers with its final t). Replies and   *)
(*      commit messages of an older attempt are ignored by the client and  *)
(*      by servers that have re-classified.                                *)
(*  D4. REPLICATE-PREPARE DOES NOT OVERWRITE. A server acks                *)
(*      ReplicatePrepare(T, t) only if it already holds T in its SpecLog   *)
(*      at exactly t. The primary leader marks T COMMITTED once f+1        *)
(*      servers (itself included) hold T at t. Replicate-Commit overwrites.*)
(*                                                                         *)
(* Rules the spec had to pin down (not yet in the design doc):             *)
(*  D5. No counter-veto. Arrival is on time iff it arrives BEFORE its     *)
(*      deadline (clock < t); an entry is released when the clock REACHES  *)
(*      its deadline (clock >= t), and D1's wait is the same "reached".    *)
(*      (The C++/Go code treats clock <= t as on time; TLC found that this *)
(*      lets a txn with t = clock land behind an entry already released at *)
(*      t, so a served read misses a write ordered before it.)             *)
(*  D6. LATE LEADER ("update T.t with its current timestamp"): t := clock  *)
(*      if (clock, id) is above highestReleasedT (a full OrderKey), and T  *)
(*      is released at once; otherwise t := highestReleasedT.t + 1, ahead  *)
(*      of the clock, and T waits in the early buffer until it's reached.  *)
(*      (The code releases at once at floor + 1; TLC found a leader read   *)
(*      placed there served before an on-time write ordered before it.)    *)
(*  D7. RECOVERY INSTALL WAITS TOO (switch InstallWait): a server installs *)
(*      the recovered M's at StartView only once its clock has reached     *)
(*      every deadline in them (D1 applied to the install path).           *)
(*                                                                         *)
(* Changes agreed 2026-11-07 (Scenario 1: a primary commits, executes and  *)
(* serves a read, then crashes before anyone learns of the commit; recovery*)
(* sees only SPEC and a deadline upgrade moves the write past the read):   *)
(*  D8. DEADLINE UPGRADE THROUGH THE PRIMARY (switch UpgradeGate; replaces *)
(*      D2/D3 for writes). A write whose leaders replied but that lacks    *)
(*      f+1 replies may be upgraded: the client sends Upgrade(t', e+1) to  *)
(*      the PRIMARY (min-id involved leader) only. The primary, atomically:*)
(*      COMMITTED -> answers "committed at t" (client accepts t); decided  *)
(*      but not yet durable (D9) -> holds the answer; otherwise PROMISES:  *)
(*      moves to (t', e+1) and ignores every message of epoch e from then  *)
(*      on. Only after the promise does the client cast t' to everyone.    *)
(*      EPOCHS: e counts upgrades; entries and all commit/sync/replication *)
(*      messages carry it; the recovery merge ranks COMMITTED first, then  *)
(*      the highest epoch, then status, then t.                            *)
(*      GHOST (switch Ghost): a server that moves a txn to a new epoch     *)
(*      keeps it blocking conflicting txns from its old t until the txn is *)
(*      COMMITTED (its final t may still fall back to the old one).        *)
(*  D9. DURABLE COMMIT (switch DurableCommit). Primary: f ReplicatePrepare *)
(*      acks -> "decided" (no upgrade promise any more), ReplicateCommit;  *)
(*      f ReplicateCommit acks -> COMMITTED, and only then executes,       *)
(*      serves reads behind it, or answers COMMITTED. Receivers of         *)
(*      ReplicateCommit mark COMMITTED and ack. f+1 COMMITTED copies means *)
(*      every recovery quorum sees one.                                    *)
(*                                                                         *)
(* Change of 2026-11-08 (TLC, REC/SCN1: a follower holds an on-time write  *)
(* w before read r and endorses r; the leader served r without w, then     *)
(* crashed; recovery sees only w at its t and commits it before r):        *)
(*  D10. READ ENDORSEMENT CHECK (switch EndorseCheck). A follower's        *)
(*      endorsement of read r carries, per key, the newest write it holds  *)
(*      ordered before r. The read's fast path counts that endorsement     *)
(*      only if it equals the leaders' results; otherwise the read waits   *)
(*      for other replies or recasts. (A write committed before r has f+1  *)
(*      on-time holders, which meet r's fast quorum: the leader includes   *)
(*      it, or the follower holds it before endorsing -- arriving later it *)
(*      is late there, since the follower's clock has reached r's t.)      *)
(*      2026-11-09: NOT SUFFICIENT alone -- recovery could turn a late or   *)
(*      missing copy into a SpecLog copy @t, manufacturing a holder (RD).  *)
(*                                                                         *)
(* Change of 2026-11-09 (TLC, RD: B held w late; recovery installed w @t   *)
(* on B from C's copy; B + C committed w @t, before a read A served):      *)
(*  D11. LATE STAYS LATE (switch LateSticky). Recovery install never makes *)
(*      a server a holder: a server that held T late (or not at all) keeps *)
(*      it late, blocking conflicting txns from its t, unless M says       *)
(*      COMMITTED. Leader sync needs a SpecLog copy, so it can't either. A *)
(*      late copy becomes a holder only by a client commit (Fast/Slow-     *)
(*      Commit: the client saw f+1 on-time holders) or Replicate-Commit.   *)
(*      A client whose write completed re-sends its commit in each new     *)
(*      view (in the code: until the leader acks), so a write that really  *)
(*      was fast-committed is not stuck; one that was not is upgraded.     *)
(*  D12. READ FLOOR (switch ReadFloor). A follower that endorses read r    *)
(*      raises its highestReleased to r's OrderKey; recovery replies carry *)
(*      highestReleased and every installer raises its own to the max in   *)
(*      the M's. A new leader then re-timestamps a late write (D6) above   *)
(*      any read the failed leader may have served (r's f endorsers meet   *)
(*      every f+1 recovery quorum). (RD with D11 only: the client restarted*)
(*      w in the new view and the new leader, late, re-timestamped it to   *)
(*      the same t, under a read the old leader had served.)               *)
(*                                                                         *)
(* Recovery (design doc "Recovery"; Go internal/vr, orderer/recovery.go):  *)
(*  - A view is (view id, alive set); its VR leader is the min-id alive    *)
(*    server. A server may suspect any peer (failures or false suspicion), *)
(*    proposing view v+1 without it: StartViewChange; after f matching     *)
(*    ones from others, DoViewChange (with its last normal view) to the VR *)
(*    leader; with f+1 the leader starts recovery from the OLDEST last-    *)
(*    normal view's alive set (ties: union).                               *)
(*  - Keys of a server that left move to the next alive server in ring     *)
(*    order (stand-in for consistent hashing: survivors keep their keys).  *)
(*  - Every member is PL for its delta-p (keys it newly leads): it collects*)
(*    f+1 RecoveryReplies (own included) -- SpecLog writes touching delta-p*)
(*    with status and t, plus the executed key-values of delta-p -- merges *)
(*    them (COMMITTED > COMMITTING > SPEC, then max t; kv: max OrderKey)   *)
(*    into M, RecoveryPrepares M, and after f+1 acks reports to the VR     *)
(*    leader, which sends StartView once every member reported.            *)
(*  - Install: key-values t-guarded; txns adopted in PL order, never       *)
(*    downgraded, never re-installed once executed; local entries not in   *)
(*    any M kept; inherited SPEC writes are then leader-synced. A server   *)
(*    that missed the round installs nothing extra.                        *)
(*  - Normal processing pauses during a view change; every message carries *)
(*    its view and is only accepted in that view. Clients learn the new    *)
(*    view (ViewInfo) and restart pending txns in it with the same t.      *)
(*  - A server left out of a view stops ("out"); rejoin is not modelled.   *)
(*                                                                         *)
(* Modelling choices (Nezha-TLA style):                                    *)
(*  - The network is a set of messages that only grows: any message may be *)
(*    delivered late, more than once, or never.                            *)
(*  - Each server's clock advances independently (arbitrary skew; clocks   *)
(*    are monotonic). A client may pick any deadline.                      *)
(*  - Each txn is driven by its own client; the workload is a constant.   *)
(*    Txn ids double as (clientId, requestId), so OrderKey = (t, id).      *)
(*  - Timeouts are nondeterministic.                                       *)
(*  - A missing body is fetched instantly (bodies are part of the model).  *)
(*  - Release is atomic with the clock (and with the end of a view change).*)
(*    An implementation whose release loop lags must not let anything else *)
(*    (late-leader re-timestamp, commit install, executor pass) act on a   *)
(*    SpecLog that is missing a due early-buffer entry.                    *)
(*  - The executor runs one txn per step against the current SpecLog. The  *)
(*    real executor decides from a snapshot and applies later; it must not *)
(*    apply a decision that a smaller conflicting entry inserted since the *)
(*    snapshot would have blocked.                                         *)
(*  - Out of scope: rejoin, RMW, reply-cache GC (Tthresh).                 *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets, Sequences, TLC

CONSTANTS
    N,           \* number of servers (2f+1)
    Workload,    \* sequence of [type |-> "W" | "R", keys |-> SUBSET Keys]
    KeyLeader,   \* function: key -> its home partition leader (a server)
    MaxTime,     \* clocks and deadlines range over 0..MaxTime
    MaxAttempt,  \* bound on (re)casts + restarts per txn
    MaxViews,    \* bound on the view id (0 = no view changes)
    MaxCrashes,  \* bound on crashed servers
    TGuard,      \* TRUE: execution never overwrites a key with an older OrderKey
    \* Rule switches. The protocol under check: WaitRule = TRUE,
    \* PrepOverwrites = FALSE, InstallWait = TRUE, UpgradeGate = TRUE,
    \* Ghost = TRUE, DurableCommit = TRUE, EndorseCheck = TRUE, LateSticky = TRUE,
    \* ReadFloor = TRUE.
    WaitRule,       \* D1 on/off
    PrepOverwrites, \* TRUE: old code -- ReplicatePrepare installs COMMITTING at t and acks
    InstallWait,    \* D7 on/off
    UpgradeGate,    \* D8 on; FALSE: D2/D3 one-step recast for writes
    Ghost,          \* D8 ghost blocking on/off
    DurableCommit,  \* D9 on; FALSE: primary COMMITTED on f prepare acks (old)
    EndorseCheck,   \* D10 on; FALSE: follower read endorsements carry nothing (old)
    LateSticky,     \* D11 on; FALSE: recovery install turns any copy into SpecLog @t (old)
    ReadFloor       \* D12 on; FALSE: read endorsements / recovery leave highestReleased alone (old)

Servers  == 1..N
F        == (N - 1) \div 2
Txns     == DOMAIN Workload
Times    == 1..MaxTime
AllKeys  == UNION {Workload[i].keys : i \in Txns}

ASSUME N \in Nat /\ N >= 1 /\ N % 2 = 1
ASSUME \A k \in AllKeys : KeyLeader[k] \in Servers

IsRead(i)  == Workload[i].type = "R"
IsWrite(i) == Workload[i].type = "W"
KeysOf(i)  == Workload[i].keys
Max(S)   == CHOOSE x \in S : \A y \in S : y <= x
Min(S)   == CHOOSE x \in S : \A y \in S : x <= y
Range(f) == {f[x] : x \in DOMAIN f}

\* Topology of a view with alive set A: a key is led by the first alive server
\* in ring order starting at its home leader.
Succ(k, d)    == ((KeyLeader[k] - 1 + d) % N) + 1
Owner(k, A)   == Succ(k, CHOOSE d \in 0..(N - 1) :
                           Succ(k, d) \in A /\ \A d2 \in 0..(d - 1) : Succ(k, d2) \notin A)
LeadersIn(i, A) == {Owner(k, A) : k \in KeysOf(i)}
\* Keys PL p newly leads when the alive set goes from oldA to A.
Delta(oldA, A, p) == {k \in AllKeys : Owner(k, A) = p /\ Owner(k, oldA) # p}

\* Two txns conflict if they share a key and at least one writes (ww, wr, rw).
Conflict(i, j) == /\ i # j
                  /\ KeysOf(i) \cap KeysOf(j) # {}
                  /\ IsWrite(i) \/ IsWrite(j)
\* OrderKey (t, id) < (t2, id2), lexicographic.
OKLess(t1, i1, t2, i2) == t1 < t2 \/ (t1 = t2 /\ i1 < i2)
Rank(st) == CASE st = "SPEC" -> 1 [] st = "COMMITTING" -> 2 [] OTHER -> 3

(***************************************************************************)
(* Variables                                                               *)
(***************************************************************************)
VARIABLES
    clock,    \* clock[s]
    ent,      \* ent[s][i]: [loc, st, t, att, ep, gt, dec]
              \*   loc: "none" | "early" | "late" | "spec" | "done"
              \*        ("done" = executed write / served leader read)
              \*   st : "NONE" | "SPEC" | "COMMITTING" | "COMMITTED"  (in spec)
              \*   t  : live deadline;  att: latest attempt seen
              \*   ep : upgrade epoch (D8);  gt: ghost deadline (0 = none)
              \*   dec: primary decided (ReplicateCommit sent), not yet durable (D9)
    highest,  \* highestReleasedT[s]: max OrderKey [t, id] ever appended to SpecLog
    store,    \* store[s][k] = [w |-> writer txn (0 = initial), t |-> its t]
    execSeq,  \* execSeq[s]: executed writes, in order, as <<id, t>>
    vst,      \* vst[s]: "normal" | "vc" | "rec" | "out" | "crashed"
    view,     \* view[s]: current (last normal) view id
    salive,   \* salive[s]: alive set of view[s]
    pv, pa,   \* view id / alive set being changed to (vc, rec)
    oldA,     \* alive set recovery starts from (rec)
    ms,       \* ms[s][p]: PL p's M as received by s: [has, txns, kvs]
    msgs,     \* all messages ever sent
    cl,       \* cl[i] = [phase, att, ep, t, v, A]: the client driving txn i
              \*   phase: "idle" | "wait" | "slow" | "upg" | "done";  (v, A): its view
    cdone,    \* history: deadline at which the client considered i committed (0 = not)
    cres,     \* history: read results, a set of <<key, writer>>
    rt        \* history: rt[i] = txns completed (at their client) before i was invoked

vrVars     == <<vst, view, salive, pv, pa, oldA, ms>>
serverOnly == <<store, execSeq>>
clientVars == <<cl, cdone, cres, rt>>
vars == <<clock, ent, highest, store, execSeq, vrVars, msgs, clientVars>>

NoEnt == [loc |-> "none", st |-> "NONE", t |-> 0, att |-> 0, ep |-> 0, gt |-> 0, dec |-> FALSE]
NoM   == [has |-> FALSE, txns |-> {}, kvs |-> {}, fl |-> [t |-> 0, id |-> 0]]

Init ==
    /\ clock   = [s \in Servers |-> 0]
    /\ ent     = [s \in Servers |-> [i \in Txns |-> NoEnt]]
    /\ highest = [s \in Servers |-> [t |-> 0, id |-> 0]]
    /\ store   = [s \in Servers |-> [k \in AllKeys |-> [w |-> 0, t |-> 0]]]
    /\ execSeq = [s \in Servers |-> <<>>]
    /\ vst     = [s \in Servers |-> "normal"]
    /\ view    = [s \in Servers |-> 0]
    /\ salive  = [s \in Servers |-> Servers]
    /\ pv      = [s \in Servers |-> 0]
    /\ pa      = [s \in Servers |-> Servers]
    /\ oldA    = [s \in Servers |-> Servers]
    /\ ms      = [s \in Servers |-> [p \in Servers |-> NoM]]
    /\ msgs    = {}
    /\ cl      = [i \in Txns |-> [phase |-> "idle", att |-> 0, ep |-> 0, t |-> 0, v |-> 0,
                                  A |-> Servers]]
    /\ cdone   = [i \in Txns |-> 0]
    /\ cres    = [i \in Txns |-> {}]
    /\ rt      = [i \in Txns |-> {}]

Send(m) == msgs' = msgs \cup m

\* Server-side helpers (in the server's current view).
Live(s)        == vst[s] \notin {"crashed", "out"}
Normal(s)      == vst[s] = "normal"
Cur(s)         == IF vst[s] = "normal" THEN view[s] ELSE pv[s]
Leaders(s, i)  == LeadersIn(i, salive[s])
IsLeader(s, i) == s \in Leaders(s, i)
Primary(s, i)  == Min(Leaders(s, i))

\* Message constructors (one record shape per type); v = sender's view, e = epoch.
MReq(i, a, t, v, kind, e)   == [type |-> "Req", txn |-> i, att |-> a, t |-> t, v |-> v, kind |-> kind,
                                ep |-> e]
MSpecRep(i, a, s, t, r, v)  == [type |-> "SpecRep", txn |-> i, att |-> a, from |-> s, t |-> t, res |-> r, v |-> v]
MFast(i, a, t, v, e)        == [type |-> "FastCommit", txn |-> i, att |-> a, t |-> t, v |-> v, ep |-> e]
MSlow(i, a, t, v, e)        == [type |-> "SlowCommit", txn |-> i, att |-> a, t |-> t, v |-> v, ep |-> e]
MCommitRep(i, a, s, t, v)   == [type |-> "CommitRep", txn |-> i, att |-> a, from |-> s, t |-> t, v |-> v]
MTsAgree(i, s, t, e, v)     == [type |-> "TsAgree", txn |-> i, from |-> s, t |-> t, ep |-> e, v |-> v]
MRepPrep(i, s, t, e, v)     == [type |-> "RepPrep", txn |-> i, from |-> s, t |-> t, ep |-> e, v |-> v]
MRepAck(i, s, t, e, v)      == [type |-> "RepAck", txn |-> i, from |-> s, t |-> t, ep |-> e, v |-> v]
MRepCommit(i, s, t, e, v)   == [type |-> "RepCommit", txn |-> i, from |-> s, t |-> t, ep |-> e, v |-> v]
MRepCommitAck(i, s, t, e, v) == [type |-> "RepCommitAck", txn |-> i, from |-> s, t |-> t, ep |-> e, v |-> v]
MUpg(i, a, e, t, v)         == [type |-> "Upg", txn |-> i, att |-> a, ep |-> e, t |-> t, v |-> v]
MUpgRep(i, a, c, t, v)      == [type |-> "UpgRep", txn |-> i, att |-> a, committed |-> c, t |-> t, v |-> v]

\* Update helpers.
SetEnt(s, i, e) == ent' = [ent EXCEPT ![s][i] = e]
\* highestReleasedT := max(highestReleasedT, (t, i)).
Bump(s, t, i)   == highest' = [highest EXCEPT ![s] =
                                 IF OKLess(@.t, @.id, t, i) THEN [t |-> t, id |-> i] ELSE @]
FinalWrite(e)   == e.st = "COMMITTED"   \* COMMITTED (executed writes stay COMMITTED)
\* Ghost deadline kept when entry e moves to a new epoch (D8): the lowest
\* position it has held, if it was in the early buffer or SpecLog.
GhostOf(e) == IF ~Ghost THEN 0
              ELSE IF e.loc \in {"early", "spec"}
                   THEN IF e.gt # 0 /\ e.gt < e.t THEN e.gt ELSE e.t
                   ELSE e.gt

\* Release loop over an ent row E of server s at clock c (alive set A): every
\* due early-buffer entry moves to SpecLog (a follower's read is only endorsed).
DueIn(E, c)        == {i \in Txns : E[i].loc = "early" /\ E[i].t <= c}
FollowerRead(A, s, i) == IsRead(i) /\ s \notin LeadersIn(i, A)
Released(E, c, A, s) ==
    [i \in Txns |->
       IF i \notin DueIn(E, c) THEN E[i]
       ELSE IF FollowerRead(A, s, i) THEN [E[i] EXCEPT !.loc = "none"]
       ELSE [E[i] EXCEPT !.loc = "spec", !.st = "SPEC"]]
\* D10: the newest write on key k that row E holds (SpecLog or executed)
\* ordered before txn i; 0 if none.
PrevW(E, i, k) ==
    LET W == {j \in Txns : /\ IsWrite(j) /\ k \in KeysOf(j)
                           /\ E[j].loc \in {"spec", "done"}
                           /\ OKLess(E[j].t, j, E[i].t, i)}
    IN IF W = {} THEN 0
       ELSE CHOOSE j \in W : \A j2 \in W : j2 = j \/ OKLess(E[j2].t, j2, E[j].t, j)
\* A follower's read endorsement carries, per key, the write it holds before
\* the read (evaluated after the release, so writes released with it count).
ReleaseReplies(E, c, A, s, v) ==
    LET E2 == Released(E, c, A, s) IN
    {MSpecRep(i, E[i].att, s, E[i].t,
              IF EndorseCheck /\ FollowerRead(A, s, i)
                THEN {<<k, PrevW(E2, i, k)>> : k \in KeysOf(i)} ELSE {},
              v) :
       i \in {j \in DueIn(E, c) : IsWrite(j) \/ FollowerRead(A, s, j)}}
\* max OrderKey among the SpecLog entries of row E and the old highestReleasedT h.
MaxOKOf(E, h) ==
    LET C == {[t |-> E[i].t, id |-> i] : i \in {j \in Txns : E[j].loc = "spec"}} \cup {h}
    IN CHOOSE x \in C : \A y \in C : ~OKLess(x.t, x.id, y.t, y.id)
MaxOK(C) == CHOOSE x \in C : \A y \in C : ~OKLess(x.t, x.id, y.t, y.id)
\* D12: the read endorsements released from row E0 at clock c raise the floor.
EndorsedFloor(E0, c, A, s) ==
    IF ReadFloor THEN {[t |-> E0[i].t, id |-> i] : i \in {j \in DueIn(E0, c) : FollowerRead(A, s, j)}}
    ELSE {}

(***************************************************************************)
(* Clocks (and the release loop, paused during a view change)              *)
(***************************************************************************)
Tick(s) ==
    LET c == clock[s] + 1
        E == IF Normal(s) THEN Released(ent[s], c, salive[s], s) ELSE ent[s]
    IN
    /\ Live(s)
    /\ clock[s] < MaxTime
    /\ clock' = [clock EXCEPT ![s] = c]
    /\ ent' = [ent EXCEPT ![s] = E]
    /\ highest' = [highest EXCEPT ![s] =
                     MaxOK({MaxOKOf(E, @)} \cup IF Normal(s) THEN EndorsedFloor(ent[s], c, salive[s], s)
                                                            ELSE {})]
    /\ IF Normal(s) THEN Send(ReleaseReplies(ent[s], c, salive[s], s, view[s]))
                    ELSE UNCHANGED msgs
    /\ UNCHANGED <<serverOnly, vrVars, clientVars>>

(***************************************************************************)
(* Client                                                                  *)
(***************************************************************************)
CLeaders(i) == LeadersIn(i, cl[i].A)

Invoke(i) ==
    /\ cl[i].phase = "idle"
    /\ \E t \in Times :
         /\ cl' = [cl EXCEPT ![i].phase = "wait", ![i].att = 1, ![i].t = t]
         /\ Send({MReq(i, 1, t, cl[i].v, "cast", 0)})
    /\ rt' = [rt EXCEPT ![i] = {j \in Txns : cdone[j] # 0}]
    /\ UNCHANGED <<clock, ent, highest, serverOnly, vrVars, cdone, cres>>

SpecReplies(i, a) == {m \in msgs : m.type = "SpecRep" /\ m.txn = i /\ m.att = a
                                   /\ m.v = cl[i].v}
RepliersAt(i, a, t) == {m.from : m \in {x \in SpecReplies(i, a) : x.t = t}}
\* D10: the leaders' read results at t; a follower endorsement counts only if
\* the writes it holds before the read are exactly those results.
LeaderRes(i, a, t) == UNION {m.res : m \in {x \in SpecReplies(i, a) :
                                              x.t = t /\ x.from \in CLeaders(i)}}
FastRepliersAt(i, a, t) ==
    IF EndorseCheck /\ IsRead(i)
    THEN {m.from : m \in {x \in SpecReplies(i, a) :
                            /\ x.t = t
                            /\ x.from \in CLeaders(i) \/ x.res = LeaderRes(i, a, t)}}
    ELSE RepliersAt(i, a, t)

\* Fast path (writes and reads): all involved leaders, >= f+1, same (view, t);
\* for reads, follower endorsements must match the leaders' results (D10).
ClientFast(i) ==
    LET a == cl[i].att IN
    /\ cl[i].phase = "wait"
    /\ \E t \in Times :
         LET S == FastRepliersAt(i, a, t) IN
         /\ CLeaders(i) \subseteq S
         /\ Cardinality(S) >= F + 1
         /\ cl'    = [cl EXCEPT ![i].phase = "done"]
         /\ cdone' = [cdone EXCEPT ![i] = t]
         /\ IF IsRead(i)
              THEN cres' = [cres EXCEPT ![i] =
                     UNION {m.res : m \in {x \in SpecReplies(i, a) :
                                             x.t = t /\ x.from \in CLeaders(i)}}]
              ELSE cres' = cres
         /\ IF IsWrite(i) THEN Send({MFast(i, a, t, cl[i].v, cl[i].ep)}) ELSE UNCHANGED msgs
    /\ UNCHANGED <<clock, ent, highest, serverOnly, vrVars, rt>>

\* Slow path (writes): all leaders replied, they disagree, >= f+1 servers replied (D2).
ClientSlow(i) ==
    LET a  == cl[i].att
        LR == {m \in SpecReplies(i, a) : m.from \in CLeaders(i)}
    IN
    /\ IsWrite(i)
    /\ cl[i].phase = "wait"
    /\ {m.from : m \in LR} = CLeaders(i)
    /\ Cardinality({m.t : m \in LR}) > 1
    /\ Cardinality({m.from : m \in SpecReplies(i, a)}) >= F + 1
    /\ cl'  = [cl EXCEPT ![i].phase = "slow"]
    /\ Send({MSlow(i, a, Max({m.t : m \in LR}), cl[i].v, cl[i].ep)})
    /\ UNCHANGED <<clock, ent, highest, serverOnly, vrVars, cdone, cres, rt>>

\* Commit-Reply quorum (after SlowCommit, or from leader sync) at one deadline.
ClientCommitReplies(i) ==
    LET a == cl[i].att IN
    /\ IsWrite(i)
    /\ cl[i].phase \in {"wait", "slow"}
    /\ \E t \in Times :
         LET S == {m.from : m \in {x \in msgs : x.type = "CommitRep" /\ x.txn = i
                                               /\ x.att = a /\ x.t = t /\ x.v = cl[i].v}}
         IN /\ CLeaders(i) \subseteq S
            /\ Cardinality(S) >= F + 1
            /\ cl'    = [cl EXCEPT ![i].phase = "done"]
            /\ cdone' = [cdone EXCEPT ![i] = t]
    /\ UNCHANGED <<clock, ent, highest, serverOnly, vrVars, msgs, cres, rt>>

\* Retry with a larger deadline: reads always; writes only without D8 (D2/D3).
ClientRecast(i) ==
    /\ IsRead(i) \/ ~UpgradeGate
    /\ cl[i].phase = "wait"
    /\ cl[i].att < MaxAttempt
    /\ \E t2 \in (cl[i].t + 1)..MaxTime :
         /\ cl' = [cl EXCEPT ![i].att = @ + 1, ![i].t = t2]
         /\ Send({MReq(i, cl[i].att + 1, t2, cl[i].v, "cast", cl[i].ep)})
    /\ UNCHANGED <<clock, ent, highest, serverOnly, vrVars, cdone, cres, rt>>

\* D8 round 1: ask the primary to upgrade the write to (t2, next epoch).
ClientUpgrade(i) ==
    /\ UpgradeGate
    /\ IsWrite(i)
    /\ cl[i].phase = "wait"
    /\ cl[i].att < MaxAttempt
    /\ \E t2 \in (cl[i].t + 1)..MaxTime :
         /\ cl' = [cl EXCEPT ![i].phase = "upg", ![i].att = @ + 1, ![i].ep = @ + 1,
                             ![i].t = t2]
         /\ Send({MUpg(i, cl[i].att + 1, cl[i].ep + 1, t2, cl[i].v)})
    /\ UNCHANGED <<clock, ent, highest, serverOnly, vrVars, cdone, cres, rt>>

\* D8 round 2: the primary answered. Committed -> accept its t; promised ->
\* cast the new deadline to every server.
ClientUpgradeReply(i) ==
    /\ cl[i].phase = "upg"
    /\ \E m \in msgs :
         /\ m.type = "UpgRep" /\ m.txn = i /\ m.att = cl[i].att /\ m.v = cl[i].v
         /\ IF m.committed
              THEN /\ cl'    = [cl EXCEPT ![i].phase = "done"]
                   /\ cdone' = [cdone EXCEPT ![i] = m.t]
                   /\ UNCHANGED msgs
              ELSE /\ cl'    = [cl EXCEPT ![i].phase = "wait"]
                   /\ Send({MReq(i, cl[i].att, cl[i].t, cl[i].v, "cast", cl[i].ep)})
                   /\ UNCHANGED cdone
    /\ UNCHANGED <<clock, ent, highest, serverOnly, vrVars, cres, rt>>

\* D11: a client whose write completed re-sends its commit (its proof that f+1
\* servers held the write on time at that t) in its current view, so a server
\* holding the write only late can become a holder after a view change.
ClientResendCommit(i) ==
    /\ LateSticky
    /\ IsWrite(i)
    /\ cl[i].phase = "done"
    /\ MFast(i, cl[i].att, cdone[i], cl[i].v, cl[i].ep) \notin msgs
    /\ Send({MFast(i, cl[i].att, cdone[i], cl[i].v, cl[i].ep)})
    /\ UNCHANGED <<clock, ent, highest, serverOnly, vrVars, clientVars>>

\* ViewInfo: adopt a newer view; restart a pending txn in it with the same t
\* (an unanswered upgrade is re-asked of the new view's primary).
ClientNewView(i) ==
    \E m \in msgs :
      /\ m.type = "ViewInfo"
      /\ m.v > cl[i].v
      /\ IF cl[i].phase \in {"wait", "slow", "upg"} /\ cl[i].att < MaxAttempt
           THEN /\ cl' = [cl EXCEPT ![i].v = m.v, ![i].A = m.A,
                                    ![i].phase = IF @ = "upg" THEN "upg" ELSE "wait",
                                    ![i].att = @ + 1]
                /\ IF cl[i].phase = "upg"
                     THEN Send({MUpg(i, cl[i].att + 1, cl[i].ep, cl[i].t, m.v)})
                     ELSE Send({MReq(i, cl[i].att + 1, cl[i].t, m.v, "restart", cl[i].ep)})
           ELSE /\ cl' = [cl EXCEPT ![i].v = m.v, ![i].A = m.A]
                /\ UNCHANGED msgs
      /\ UNCHANGED <<clock, ent, highest, serverOnly, vrVars, cdone, cres, rt>>

(***************************************************************************)
(* Server: arrival                                                         *)
(***************************************************************************)
\* Classify an arrival of txn i at deadline t (attempt a, epoch e, ghost g).
Classified(s, i, t, a, e, g) ==
    LET aboveFloor == OKLess(highest[s].t, highest[s].id, clock[s], i)
        newT == IF aboveFloor THEN clock[s] ELSE highest[s].t + 1
        mk(l, st, tt) == [loc |-> l, st |-> st, t |-> tt, att |-> a, ep |-> e, gt |-> g,
                          dec |-> FALSE]
    IN
    IF clock[s] < t THEN mk("early", "NONE", t)       \* on time -> early buffer
    ELSE IF IsLeader(s, i) THEN                         \* late at a leader (D6)
         IF aboveFloor THEN mk("spec", "SPEC", newT)    \*   released at once
                       ELSE mk("early", "NONE", newT)   \*   waits for floor + 1
    ELSE IF IsWrite(i) THEN mk("late", "NONE", t)       \* late write at a pure follower
    ELSE [NoEnt EXCEPT !.att = a]                       \* late read at a pure follower: dropped

\* Admit the arrival: store the classified entry; a write released at once
\* (late leader) replies at once; a read is served by the executor.
Arrive(s, i, t, a, e, g, extra) ==
    LET E == Classified(s, i, t, a, e, g) IN
    /\ E.t <= MaxTime                                   \* model bound
    /\ SetEnt(s, i, E)
    /\ IF E.loc = "spec" THEN Bump(s, E.t, i) ELSE UNCHANGED highest
    /\ Send(extra \cup IF E.loc = "spec" /\ IsWrite(i)
                       THEN {MSpecRep(i, a, s, E.t, {}, view[s])} ELSE {})

RecvRequest(s, m) ==
    LET i == m.txn
        e == ent[s][i]
        restart == m.kind = "restart" /\ m.ep = e.ep
    IN
    /\ m.type = "Req"
    /\ Normal(s)
    /\ m.v = view[s]
    /\ m.att > e.att                                   \* each attempt handled once
    /\ IF IsWrite(i) /\ FinalWrite(e) THEN
          \* COMMITTED / executed: never touched; answer with the final t.
          /\ SetEnt(s, i, [e EXCEPT !.att = m.att])
          /\ Send({MSpecRep(i, m.att, s, e.t, {}, view[s])})
          /\ UNCHANGED highest
       ELSE IF m.ep < e.ep THEN
          \* From an older epoch than one already adopted: ignored.
          /\ SetEnt(s, i, [e EXCEPT !.att = m.att])
          /\ UNCHANGED <<msgs, highest>>
       ELSE IF restart /\ e.loc = "spec" THEN
          \* View-change restart (same t): answer from the live entry.
          /\ SetEnt(s, i, [e EXCEPT !.att = m.att])
          /\ IF IsWrite(i) THEN Send({MSpecRep(i, m.att, s, e.t, {}, view[s])})
                           ELSE UNCHANGED msgs
          /\ UNCHANGED highest
       ELSE IF restart /\ e.loc = "early" THEN
          /\ SetEnt(s, i, [e EXCEPT !.att = m.att])     \* replies on release
          /\ UNCHANGED <<msgs, highest>>
       ELSE
          \* (Re-)classify: a new epoch keeps a ghost of the old position (D8);
          \* a same-epoch recast (D3, reads) also leaves SpecLog.
          Arrive(s, i, m.t, m.att, m.ep, IF m.ep > e.ep THEN GhostOf(e) ELSE e.gt, {})
    /\ UNCHANGED <<clock, serverOnly, vrVars, clientVars>>

\* D8: the primary answers an upgrade request atomically.
RecvUpgrade(s, m) ==
    LET i == m.txn
        e == ent[s][i]
    IN
    /\ m.type = "Upg"
    /\ Normal(s)
    /\ m.v = view[s]
    /\ s = Primary(s, i)
    /\ ~e.dec                                \* decided, not yet durable: hold the answer
    /\ IF FinalWrite(e) THEN
          \* COMMITTED: tell the client its final t; no upgrade.
          /\ Send({MUpgRep(i, m.att, TRUE, e.t, view[s])})
          /\ UNCHANGED <<ent, highest>>
       ELSE IF e.ep >= m.ep THEN
          \* Already promised this epoch: answer again.
          /\ e.ep = m.ep
          /\ Send({MUpgRep(i, m.att, FALSE, m.t, view[s])})
          /\ UNCHANGED <<ent, highest>>
       ELSE
          \* Promise: move to (t', new epoch); epoch-e messages are ignored from now on.
          Arrive(s, i, m.t, m.att, m.ep, GhostOf(e), {MUpgRep(i, m.att, FALSE, m.t, view[s])})
    /\ UNCHANGED <<clock, serverOnly, vrVars, clientVars>>

(***************************************************************************)
(* Server: Fast-Commit / Slow-Commit (D1: wait until clock >= t)           *)
(***************************************************************************)
RecvCommit(s, m) ==
    LET i == m.txn
        e == ent[s][i]
        slow == m.type = "SlowCommit"
    IN
    /\ m.type \in {"FastCommit", "SlowCommit"}
    /\ Normal(s)
    /\ m.v = view[s]
    /\ m.att >= e.att                       \* stale attempt: ignored (D3)
    /\ m.ep >= e.ep                         \* stale epoch: ignored (D8)
    /\ WaitRule => clock[s] >= m.t          \* D1
    /\ IF FinalWrite(e) \/ e.dec THEN
          \* COMMITTED, or decided at the primary: t is final.
          /\ UNCHANGED <<ent, highest>>
          /\ IF slow THEN Send({MCommitRep(i, m.att, s, e.t, view[s])}) ELSE UNCHANGED msgs
       ELSE
          \* Found in SpecLog / early / late buffer, or fetched: adopt t, COMMITTING.
          /\ SetEnt(s, i, [loc |-> "spec", st |-> "COMMITTING", t |-> m.t, att |-> m.att,
                           ep |-> m.ep, gt |-> IF m.ep > e.ep THEN GhostOf(e) ELSE e.gt,
                           dec |-> FALSE])
          /\ Bump(s, m.t, i)
          /\ IF slow THEN Send({MCommitRep(i, m.att, s, m.t, view[s])}) ELSE UNCHANGED msgs
    /\ UNCHANGED <<clock, serverOnly, vrVars, clientVars>>

(***************************************************************************)
(* Background: leader sync (TsAgree)                                       *)
(***************************************************************************)
ProposeTs(s, i) ==
    /\ Normal(s)
    /\ IsWrite(i)
    /\ IsLeader(s, i)
    /\ ent[s][i].loc \in {"spec", "done"}
    /\ Send({MTsAgree(i, s, ent[s][i].t, ent[s][i].ep, view[s])})
    /\ UNCHANGED <<clock, ent, highest, serverOnly, vrVars, clientVars>>

\* SPECULATIVE past the timeout (or inherited at recovery): with a proposal from
\* every other involved leader, take the max, wait until clock >= max (D1), mark
\* COMMITTING, CommitReply the client.
LeaderSync(s, i) ==
    LET e == ent[s][i] IN
    /\ Normal(s)
    /\ IsWrite(i)
    /\ IsLeader(s, i)
    /\ e.loc = "spec"
    /\ e.st = "SPEC"
    /\ \E P \in [Leaders(s, i) \ {s} -> Times] :
         LET agreed == Max({e.t} \cup Range(P)) IN
         /\ \A l \in Leaders(s, i) \ {s} : MTsAgree(i, l, P[l], e.ep, view[s]) \in msgs
         /\ WaitRule => clock[s] >= agreed
         /\ SetEnt(s, i, [e EXCEPT !.st = "COMMITTING", !.t = agreed])
         /\ Bump(s, agreed, i)
         /\ Send({MCommitRep(i, e.att, s, agreed, view[s])})
    /\ UNCHANGED <<clock, serverOnly, vrVars, clientVars>>

(***************************************************************************)
(* Background: replication (D4)                                            *)
(***************************************************************************)
SendPrepare(s, i) ==
    /\ Normal(s)
    /\ IsWrite(i)
    /\ s = Primary(s, i)
    /\ ent[s][i].loc = "spec"
    /\ ent[s][i].st = "COMMITTING"
    /\ ~ent[s][i].dec
    /\ Send({MRepPrep(i, s, ent[s][i].t, ent[s][i].ep, view[s])})
    /\ UNCHANGED <<clock, ent, highest, serverOnly, vrVars, clientVars>>

\* Ack only if already holding the txn in SpecLog at exactly (t, epoch); never overwrite.
RecvPrepare(s, m) ==
    LET e == ent[s][m.txn] IN
    /\ m.type = "RepPrep"
    /\ Normal(s)
    /\ m.v = view[s]
    /\ s # m.from
    /\ IF PrepOverwrites /\ ~FinalWrite(e) THEN
          \* Old code (installCommittingLocked): adopt from anywhere, then ack.
          /\ WaitRule => clock[s] >= m.t
          /\ SetEnt(s, m.txn, [loc |-> "spec", st |-> "COMMITTING", t |-> m.t, att |-> e.att,
                               ep |-> m.ep, gt |-> e.gt, dec |-> FALSE])
          /\ Bump(s, m.t, m.txn)
       ELSE
          /\ e.loc \in {"spec", "done"}
          /\ e.t = m.t
          /\ e.ep = m.ep
          /\ UNCHANGED <<ent, highest>>
    /\ Send({MRepAck(m.txn, s, m.t, m.ep, view[s])})
    /\ UNCHANGED <<clock, serverOnly, vrVars, clientVars>>

\* f+1 holders including the primary -> decided (D9) or COMMITTED (old);
\* Replicate-Commit to all.
PrimaryDecide(s, i) ==
    LET e == ent[s][i] IN
    /\ Normal(s)
    /\ IsWrite(i)
    /\ s = Primary(s, i)
    /\ e.loc = "spec"
    /\ e.st = "COMMITTING"
    /\ ~e.dec
    /\ Cardinality({q \in Servers \ {s} : MRepAck(i, q, e.t, e.ep, view[s]) \in msgs}) >= F
    /\ IF DurableCommit THEN SetEnt(s, i, [e EXCEPT !.dec = TRUE])
                        ELSE SetEnt(s, i, [e EXCEPT !.st = "COMMITTED", !.gt = 0])
    /\ Send({MRepCommit(i, s, e.t, e.ep, view[s])})
    /\ UNCHANGED <<clock, highest, serverOnly, vrVars, clientVars>>

\* A decided server re-sends Replicate-Commit (e.g. in a new view).
ResendDecision(s, i) ==
    LET e == ent[s][i] IN
    /\ Normal(s)
    /\ e.dec
    /\ Send({MRepCommit(i, s, e.t, e.ep, view[s])})
    /\ UNCHANGED <<clock, ent, highest, serverOnly, vrVars, clientVars>>

\* D9: f Replicate-Commit acks -> the decision is durable -> COMMITTED.
PrimaryDurable(s, i) ==
    LET e == ent[s][i] IN
    /\ Normal(s)
    /\ e.dec
    /\ Cardinality({q \in Servers \ {s} : MRepCommitAck(i, q, e.t, e.ep, view[s]) \in msgs}) >= F
    /\ SetEnt(s, i, [e EXCEPT !.st = "COMMITTED", !.gt = 0, !.dec = FALSE])
    /\ UNCHANGED <<clock, highest, serverOnly, vrVars, msgs, clientVars>>

\* Replicate-Commit overwrites (still waiting until clock >= t, D1); acked under D9.
RecvRepCommit(s, m) ==
    LET e == ent[s][m.txn] IN
    /\ m.type = "RepCommit"
    /\ Normal(s)
    /\ m.v = view[s]
    /\ s # m.from
    /\ WaitRule => clock[s] >= m.t
    /\ IF FinalWrite(e) THEN
          /\ e.t = m.t
          /\ UNCHANGED <<ent, highest>>
       ELSE
          /\ SetEnt(s, m.txn, [loc |-> "spec", st |-> "COMMITTED", t |-> m.t, att |-> e.att,
                               ep |-> m.ep, gt |-> 0, dec |-> FALSE])
          /\ Bump(s, m.t, m.txn)
    /\ IF DurableCommit THEN Send({MRepCommitAck(m.txn, s, m.t, m.ep, view[s])})
                        ELSE UNCHANGED msgs
    /\ UNCHANGED <<clock, serverOnly, vrVars, clientVars>>

(***************************************************************************)
(* Execution (dependency order) and leader reads                           *)
(***************************************************************************)
\* No smaller-OrderKey conflicting txn is still in s's SpecLog, and no
\* conflicting txn holds a ghost below i (D8).
Unblocked(s, i) ==
    ~\E j \in Txns : /\ Conflict(i, j)
                     /\ \/ /\ ent[s][j].loc = "spec"
                           /\ OKLess(ent[s][j].t, j, ent[s][i].t, i)
                        \/ /\ ent[s][j].gt # 0
                           /\ ent[s][j].loc \in {"early", "spec", "late"}
                           /\ OKLess(ent[s][j].gt, j, ent[s][i].t, i)

ExecuteWrite(s, i) ==
    LET e == ent[s][i] IN
    /\ Live(s)
    /\ IsWrite(i)
    /\ e.loc = "spec"
    /\ e.st = "COMMITTED"
    /\ Unblocked(s, i)
    /\ store' = [store EXCEPT ![s] =
                   [k \in AllKeys |->
                      IF k \in KeysOf(i)
                         /\ ~(TGuard /\ OKLess(e.t, i, store[s][k].t, store[s][k].w))
                      THEN [w |-> i, t |-> e.t]
                      ELSE store[s][k]]]
    /\ execSeq' = [execSeq EXCEPT ![s] = Append(@, <<i, e.t>>)]
    /\ SetEnt(s, i, [e EXCEPT !.loc = "done"])
    /\ UNCHANGED <<clock, highest, vrVars, msgs, clientVars>>

\* A leader read is served once no smaller conflicting write is pending; it reads
\* the keys this server leads and replies with the results.
ServeRead(s, i) ==
    LET e == ent[s][i] IN
    /\ Normal(s)
    /\ IsRead(i)
    /\ IsLeader(s, i)
    /\ e.loc = "spec"
    /\ Unblocked(s, i)
    /\ SetEnt(s, i, [e EXCEPT !.loc = "done"])
    /\ Send({MSpecRep(i, e.att, s, e.t,
                      {<<k, store[s][k].w>> : k \in {x \in KeysOf(i) : Owner(x, salive[s]) = s}},
                      view[s])})
    /\ UNCHANGED <<clock, highest, serverOnly, vrVars, clientVars>>

(***************************************************************************)
(* Recovery: failures and the VR layer                                     *)
(***************************************************************************)
Crash(s) ==
    /\ Live(s)
    /\ Cardinality({x \in Servers : vst[x] = "crashed"}) < MaxCrashes
    /\ vst' = [vst EXCEPT ![s] = "crashed"]
    /\ UNCHANGED <<clock, ent, highest, serverOnly, view, salive, pv, pa, oldA, ms,
                   msgs, clientVars>>

\* s suspects peer x (crashed or not): propose view Cur+1 without it.
StartVC(s) ==
    /\ vst[s] \in {"normal", "vc"}
    /\ Cur(s) < MaxViews
    /\ \E x \in salive[s] \ {s} :
         LET A2 == salive[s] \ {x}
             v2 == Cur(s) + 1
         IN /\ Cardinality(A2) >= F + 1
            /\ vst'  = [vst EXCEPT ![s] = "vc"]
            /\ pv'   = [pv EXCEPT ![s] = v2]
            /\ pa'   = [pa EXCEPT ![s] = A2]
            /\ oldA' = [oldA EXCEPT ![s] = IF Normal(s) THEN salive[s] ELSE @]
            /\ Send({[type |-> "SVC", v |-> v2, from |-> s, A |-> A2]})
    /\ UNCHANGED <<clock, ent, highest, serverOnly, view, salive, ms, clientVars>>

\* Join a higher view change that includes us.
JoinVC(s, m) ==
    /\ m.type = "SVC"
    /\ vst[s] \in {"normal", "vc", "rec"}
    /\ s \in m.A
    /\ m.v > Cur(s)
    /\ vst'  = [vst EXCEPT ![s] = "vc"]
    /\ pv'   = [pv EXCEPT ![s] = m.v]
    /\ pa'   = [pa EXCEPT ![s] = m.A]
    /\ oldA' = [oldA EXCEPT ![s] = IF Normal(s) THEN salive[s] ELSE @]
    /\ Send({[type |-> "SVC", v |-> m.v, from |-> s, A |-> m.A]})
    /\ UNCHANGED <<clock, ent, highest, serverOnly, view, salive, ms, clientVars>>

\* f matching StartViewChanges from others: DoViewChange (with last normal view).
SendDVC(s) ==
    /\ vst[s] = "vc"
    /\ Cardinality({m.from : m \in {x \in msgs : x.type = "SVC" /\ x.v = pv[s]
                                               /\ x.A = pa[s] /\ x.from # s}}) >= F
    /\ Send({[type |-> "DVC", v |-> pv[s], from |-> s, A |-> pa[s],
              lnv |-> view[s], oldA |-> oldA[s]]})
    /\ UNCHANGED <<clock, ent, highest, serverOnly, vrVars, clientVars>>

\* Enter recovery of view v (alive A) from old alive set oA; ask every PL's data.
EnterRec(s, v, A, oA) ==
    /\ vst'  = [vst EXCEPT ![s] = "rec"]
    /\ pv'   = [pv EXCEPT ![s] = v]
    /\ pa'   = [pa EXCEPT ![s] = A]
    /\ oldA' = [oldA EXCEPT ![s] = oA]
    /\ ms'   = [ms EXCEPT ![s] = [p \in Servers |-> NoM]]

\* VR leader with f+1 DoViewChanges (itself included): recover from the oldest
\* last-normal view among them (ties: union of their alive sets).
LeaderStartRec(s) ==
    /\ vst[s] = "vc"
    /\ s = Min(pa[s])
    /\ \E Q \in SUBSET {m \in msgs : m.type = "DVC" /\ m.v = pv[s] /\ m.A = pa[s]} :
         LET from == {m.from : m \in Q}
             lo   == Min({m.lnv : m \in Q})
             oA   == UNION {m.oldA : m \in {x \in Q : x.lnv = lo}}
         IN /\ Cardinality(from) = Cardinality(Q)          \* one per sender
            /\ s \in from
            /\ Cardinality(Q) >= F + 1
            /\ EnterRec(s, pv[s], pa[s], oA)
            /\ Send({[type |-> "StartRec", v |-> pv[s], A |-> pa[s], oldA |-> oA],
                     [type |-> "RecReq", v |-> pv[s], from |-> s, A |-> pa[s], oldA |-> oA]})
    /\ UNCHANGED <<clock, ent, highest, serverOnly, view, salive, clientVars>>

\* StartRecovery / RecoveryRequest / RecoveryPrepare of a newer round: join it.
AcceptRec(s, m) ==
    /\ m.type \in {"StartRec", "RecReq", "RecPrep"}
    /\ vst[s] \in {"normal", "vc", "rec"}
    /\ s \in m.A
    /\ m.v >= Cur(s)
    /\ ~(Normal(s) /\ m.v = view[s])
    /\ ~(vst[s] = "rec" /\ m.v = pv[s])
    /\ EnterRec(s, m.v, m.A, m.oldA)
    /\ Send({[type |-> "RecReq", v |-> m.v, from |-> s, A |-> m.A, oldA |-> m.oldA]})
    /\ UNCHANGED <<clock, ent, highest, serverOnly, view, salive, clientVars>>

\* Left out of a newer view: stop (rejoin not modelled).
Excluded(s, m) ==
    /\ m.type \in {"StartRec", "RecReq", "RecPrep", "StartView"}
    /\ Live(s)
    /\ s \notin m.A
    /\ m.v > Cur(s)
    /\ vst' = [vst EXCEPT ![s] = "out"]
    /\ UNCHANGED <<clock, ent, highest, serverOnly, view, salive, pv, pa, oldA, ms,
                   msgs, clientVars>>

\* What server s contributes to PL p's M: its SpecLog writes touching D (with
\* status and t) and its executed key-values in D.
Data(s, D) ==
    [txns |-> {[id |-> i, t |-> ent[s][i].t, ep |-> ent[s][i].ep,
                \* a decided entry is reported as COMMITTED (f+1 hold it at t)
                st |-> IF ent[s][i].dec THEN "COMMITTED" ELSE ent[s][i].st] :
                 i \in {j \in Txns : IsWrite(j) /\ ent[s][j].loc = "spec"
                                     /\ KeysOf(j) \cap D # {}}},
     kvs  |-> {[k |-> k, w |-> store[s][k].w, t |-> store[s][k].t] :
                 k \in {x \in D : store[s][x].w # 0}},
     fl   |-> highest[s]]   \* D12: its highestReleased (incl. endorsed reads)

AnswerRecReq(s, m) ==
    /\ m.type = "RecReq"
    /\ vst[s] = "rec"
    /\ pv[s] = m.v
    /\ Send({[type |-> "RecRep", v |-> m.v, from |-> s, to |-> m.from,
              d |-> Data(s, Delta(m.oldA, m.A, m.from))]})
    /\ UNCHANGED <<clock, ent, highest, serverOnly, vrVars, clientVars>>

\* Merge: per txn COMMITTED first, then the highest epoch (D8), then
\* COMMITTING > SPEC, then max t; per key max OrderKey.
Better(r1, r2) ==
    LET c1 == r1.st = "COMMITTED"
        c2 == r2.st = "COMMITTED"
    IN \/ c1 /\ ~c2
       \/ c1 = c2 /\ r1.ep > r2.ep
       \/ c1 = c2 /\ r1.ep = r2.ep /\ Rank(r1.st) > Rank(r2.st)
       \/ c1 = c2 /\ r1.ep = r2.ep /\ Rank(r1.st) = Rank(r2.st) /\ r1.t > r2.t
Merge(DS) ==
    LET T == UNION {d.txns : d \in DS}
        K == UNION {d.kvs : d \in DS}
    IN [has  |-> TRUE,
        txns |-> {CHOOSE r \in T : r.id = id /\ \A r2 \in T : r2.id = id => ~Better(r2, r) :
                    id \in {r.id : r \in T}},
        kvs  |-> {CHOOSE x \in K : x.k = k /\ \A y \in K : y.k = k => ~OKLess(x.t, x.w, y.t, y.w) :
                    k \in {x.k : x \in K}},
        fl   |-> MaxOK({d.fl : d \in DS})]

Built(s) == \E m \in msgs : m.type = "RecPrep" /\ m.v = pv[s] /\ m.from = s

\* PL with f+1 RecoveryReplies (own included): build M, RecoveryPrepare it.
BuildM(s) ==
    /\ vst[s] = "rec"
    /\ ~Built(s)
    /\ \E Q \in SUBSET {m \in msgs : m.type = "RecRep" /\ m.v = pv[s] /\ m.to = s} :
         LET from == {m.from : m \in Q}
             M    == Merge({m.d : m \in Q})
         IN /\ Cardinality(from) = Cardinality(Q)
            /\ s \in from
            /\ Cardinality(Q) >= F + 1
            /\ ms' = [ms EXCEPT ![s][s] = M]
            /\ Send({[type |-> "RecPrep", v |-> pv[s], from |-> s, A |-> pa[s],
                      oldA |-> oldA[s], M |-> M]})
    /\ UNCHANGED <<clock, ent, highest, serverOnly, vst, view, salive, pv, pa, oldA,
                   clientVars>>

AcceptPrep(s, m) ==
    /\ m.type = "RecPrep"
    /\ \/ /\ vst[s] = "rec" /\ pv[s] = m.v
          /\ ms' = [ms EXCEPT ![s][m.from] = m.M]
       \/ /\ Normal(s) /\ view[s] = m.v               \* already installed: just ack
          /\ UNCHANGED ms
    /\ Send({[type |-> "RecPrepAck", v |-> m.v, from |-> s, to |-> m.from]})
    /\ UNCHANGED <<clock, ent, highest, serverOnly, vst, view, salive, pv, pa, oldA,
                   clientVars>>

\* M prepared on f+1 (PL included): report to the VR leader.
Report(s) ==
    /\ vst[s] = "rec"
    /\ Built(s)
    /\ Cardinality({s} \cup {m.from : m \in {x \in msgs : x.type = "RecPrepAck"
                                              /\ x.v = pv[s] /\ x.to = s}}) >= F + 1
    /\ Send({[type |-> "Report", v |-> pv[s], from |-> s]})
    /\ UNCHANGED <<clock, ent, highest, serverOnly, vrVars, clientVars>>

\* VR leader: every member reported -> StartView.
SendStartView(s) ==
    /\ vst[s] = "rec"
    /\ s = Min(pa[s])
    /\ \A p \in pa[s] : [type |-> "Report", v |-> pv[s], from |-> p] \in msgs
    /\ Send({[type |-> "StartView", v |-> pv[s], A |-> pa[s]]})
    /\ UNCHANGED <<clock, ent, highest, serverOnly, vrVars, clientVars>>

\* Install one recovered txn record r over entry e (never downgrade, never
\* re-install an executed txn; an early-buffer copy is kept unless r is decided).
\* A COMMITTED record wins; otherwise a newer epoch wins (leaving a ghost, D8).
InstallOne(e, r) ==
    IF e.loc = "done" \/ e.st = "COMMITTED" THEN e
    ELSE IF r.st = "COMMITTED"
         THEN [loc |-> "spec", st |-> "COMMITTED", t |-> r.t, att |-> e.att, ep |-> r.ep,
               gt |-> 0, dec |-> FALSE]
    ELSE IF LateSticky /\ e.loc \in {"none", "late"} /\ r.ep >= e.ep
         \* D11: a server that did not hold T on time does not become a holder by
         \* recovery: it keeps T late (body only), blocking from r.t like a ghost.
         THEN [loc |-> "late", st |-> "NONE", t |-> r.t, att |-> e.att, ep |-> r.ep,
               gt |-> r.t, dec |-> FALSE]
    ELSE IF r.ep > e.ep
         THEN [loc |-> "spec", st |-> r.st, t |-> r.t, att |-> e.att, ep |-> r.ep,
               gt |-> GhostOf(e), dec |-> FALSE]
    ELSE IF r.ep < e.ep \/ e.dec THEN e
    ELSE IF e.loc = "spec"
         THEN IF Rank(r.st) > Rank(e.st) THEN [e EXCEPT !.t = r.t, !.st = r.st] ELSE e
    ELSE IF e.loc = "early" /\ r.st = "SPEC" THEN e
    ELSE [e EXCEPT !.loc = "spec", !.st = r.st, !.t = r.t]

\* Fold the M's of PLs p..N (in PL order) into entry e of txn i.
RECURSIVE InstFold(_, _, _, _)
InstFold(e, i, MM, p) ==
    IF p > N THEN e
    ELSE InstFold(IF MM[p].has /\ \E r \in MM[p].txns : r.id = i
                  THEN InstallOne(e, CHOOSE r \in MM[p].txns : r.id = i)
                  ELSE e,
                  i, MM, p + 1)

\* StartView: install every M received (none if the round was missed), resume
\* in the new view, release what became due while paused, tell clients.
Install(s, m) ==
    LET inRound == vst[s] = "rec" /\ pv[s] = m.v
        MM   == IF inRound THEN ms[s] ELSE [p \in Servers |-> NoM]
        Ts   == UNION {{r.t : r \in MM[p].txns} : p \in Servers}
        KV   == UNION {MM[p].kvs : p \in Servers}
        E1   == [i \in Txns |-> InstFold(ent[s][i], i, MM, 1)]
        E2   == Released(E1, clock[s], m.A, s)
        bestKV(k) == CHOOSE x \in KV : x.k = k /\ \A y \in KV : y.k = k => ~OKLess(x.t, x.w, y.t, y.w)
    IN
    /\ m.type = "StartView"
    /\ Live(s)
    /\ s \in m.A
    /\ inRound \/ m.v > Cur(s)
    /\ InstallWait => \A t \in Ts : clock[s] >= t        \* D7
    /\ store' = [store EXCEPT ![s] =
                   [k \in AllKeys |->
                      IF \E x \in KV : x.k = k
                      THEN IF OKLess(store[s][k].t, store[s][k].w, bestKV(k).t, bestKV(k).w)
                           THEN [w |-> bestKV(k).w, t |-> bestKV(k).t]
                           ELSE store[s][k]
                      ELSE store[s][k]]]
    /\ ent'     = [ent EXCEPT ![s] = E2]
    \* D12: the new floor also covers every floor reported in the M's.
    /\ highest' = [highest EXCEPT ![s] =
                     MaxOK({MaxOKOf(E2, @)} \cup EndorsedFloor(E1, clock[s], m.A, s)
                           \cup IF ReadFloor THEN {MM[p].fl : p \in {q \in Servers : MM[q].has}}
                                 ELSE {})]
    /\ vst'     = [vst EXCEPT ![s] = "normal"]
    /\ view'    = [view EXCEPT ![s] = m.v]
    /\ salive'  = [salive EXCEPT ![s] = m.A]
    /\ pv'      = [pv EXCEPT ![s] = m.v]
    /\ pa'      = [pa EXCEPT ![s] = m.A]
    /\ ms'      = [ms EXCEPT ![s] = [p \in Servers |-> NoM]]
    /\ Send({[type |-> "ViewInfo", v |-> m.v, A |-> m.A]}
            \cup ReleaseReplies(E1, clock[s], m.A, s, m.v))
    /\ UNCHANGED <<clock, execSeq, oldA, clientVars>>

(***************************************************************************)
(* Next state                                                              *)
(***************************************************************************)
Next ==
    \/ \E s \in Servers : Tick(s)
    \/ \E i \in Txns : Invoke(i) \/ ClientFast(i) \/ ClientSlow(i)
                       \/ ClientCommitReplies(i) \/ ClientRecast(i) \/ ClientNewView(i)
                       \/ ClientUpgrade(i) \/ ClientUpgradeReply(i) \/ ClientResendCommit(i)
    \/ \E s \in Servers, m \in msgs :
         \/ RecvRequest(s, m) \/ RecvCommit(s, m) \/ RecvPrepare(s, m) \/ RecvRepCommit(s, m)
         \/ RecvUpgrade(s, m)
         \/ JoinVC(s, m) \/ AcceptRec(s, m) \/ Excluded(s, m) \/ AnswerRecReq(s, m)
         \/ AcceptPrep(s, m) \/ Install(s, m)
    \/ \E s \in Servers, i \in Txns :
         ProposeTs(s, i) \/ LeaderSync(s, i) \/ SendPrepare(s, i) \/ PrimaryDecide(s, i)
         \/ ResendDecision(s, i) \/ PrimaryDurable(s, i)
         \/ ExecuteWrite(s, i) \/ ServeRead(s, i)
    \/ \E s \in Servers :
         Crash(s) \/ StartVC(s) \/ SendDVC(s) \/ LeaderStartRec(s) \/ BuildM(s)
         \/ Report(s) \/ SendStartView(s)

Spec == Init /\ [][Next]_vars

(***************************************************************************)
(* Properties                                                              *)
(***************************************************************************)
\* Deadlines at which some server holds write i COMMITTED.
CommitTs(i) == {ent[s][i].t : s \in {x \in Servers : ent[x][i].st = "COMMITTED"}}
\* The deadline i is committed at: what its client saw, else what servers hold.
FinalT(i) == IF cdone[i] # 0 THEN cdone[i]
             ELSE IF CommitTs(i) # {} THEN Max(CommitTs(i)) ELSE 0
Committed(i) == FinalT(i) # 0

TypeOK ==
    /\ clock \in [Servers -> 0..MaxTime]
    /\ highest \in [Servers -> [t : 0..MaxTime, id : {0} \cup Txns]]
    /\ vst \in [Servers -> {"normal", "vc", "rec", "out", "crashed"}]
    /\ view \in [Servers -> 0..MaxViews]
    /\ \A s \in Servers, i \in Txns :
         /\ ent[s][i].loc \in {"none", "early", "late", "spec", "done"}
         /\ ent[s][i].st \in {"NONE", "SPEC", "COMMITTING", "COMMITTED"}
         /\ ent[s][i].ep \in 0..MaxAttempt
         /\ ent[s][i].gt \in 0..MaxTime
         /\ ent[s][i].dec \in BOOLEAN
         /\ ent[s][i].dec => ent[s][i].st = "COMMITTING"
    /\ \A i \in Txns : cl[i].phase \in {"idle", "wait", "slow", "upg", "done"}

\* AGREEMENT: a write commits at one deadline everywhere, and it is the one its
\* client was told.
Agreement ==
    \A i \in Txns : IsWrite(i) =>
        /\ Cardinality(CommitTs(i)) <= 1
        /\ cdone[i] # 0 => CommitTs(i) \subseteq {cdone[i]}

\* WAIT RULE (D1): no live server holds a txn COMMITTING/COMMITTED at a
\* deadline its clock hasn't reached.
NoCommitAhead ==
    \A s \in Servers, i \in Txns :
        (Live(s) /\ ent[s][i].st \in {"COMMITTING", "COMMITTED"}) => clock[s] >= ent[s][i].t

\* Nothing sits in a live server's SpecLog (or was executed/served) at a deadline
\* its clock hasn't reached (D1, D5, D6, D7).
SpecReached ==
    \A s \in Servers, i \in Txns :
        (Live(s) /\ ent[s][i].loc \in {"spec", "done"}) => clock[s] >= ent[s][i].t

\* REAL-TIME ORDER: if i completed before j was invoked and j commits, j's
\* OrderKey is larger. (Applies to j even if its own client never learned of it.)
RealTimeOrder ==
    \A i, j \in Txns :
        (i \in rt[j] /\ Committed(j)) => OKLess(FinalT(i), i, FinalT(j), j)

\* READ CONSISTENCY: a completed read returns, for each key, the committed write
\* with the largest OrderKey below the read's (or the initial value).
ReadConsistency ==
    \A r \in Txns : (IsRead(r) /\ cdone[r] # 0) =>
        \A k \in KeysOf(r) :
            \E p \in cres[r] :
                /\ p[1] = k
                /\ LET w == p[2] IN
                   /\ w # 0 => (Committed(w) /\ OKLess(FinalT(w), w, cdone[r], r))
                   /\ \A w2 \in Txns \ {w} :
                        (/\ IsWrite(w2) /\ k \in KeysOf(w2) /\ Committed(w2)
                         /\ OKLess(FinalT(w2), w2, cdone[r], r))
                        => (w # 0 /\ OKLess(FinalT(w2), w2, FinalT(w), w))

\* DURABILITY at the leader: in the newest view, the current leader of a key of a
\* client-committed write holds that write at its deadline, or a value on the
\* key at least as new. (A server still Normal in an older view is stale: it
\* can neither execute nor answer COMMITTED without acks from the new view.)
LeaderKnows ==
    \A i \in Txns : (IsWrite(i) /\ cdone[i] # 0) =>
        \A s \in Servers : (Normal(s) /\ view[s] = Max({view[x] : x \in Servers})) =>
            \A k \in {x \in KeysOf(i) : Owner(x, salive[s]) = s} :
                \/ ent[s][i].loc \in {"spec", "done"} /\ ent[s][i].t = cdone[i]
                \* D11: held late (blocking from its t) until the client's commit arrives
                \/ LateSticky /\ ent[s][i].loc = "late" /\ ent[s][i].gt = cdone[i]
                \/ ~OKLess(store[s][k].t, store[s][k].w, cdone[i], i)

\* EXECUTION ORDER: every server executes conflicting writes in OrderKey order.
ExecOrder ==
    \A s \in Servers :
        \A p, q \in 1..Len(execSeq[s]) :
            (p < q /\ Conflict(execSeq[s][p][1], execSeq[s][q][1]))
            => OKLess(execSeq[s][p][2], execSeq[s][p][1],
                      execSeq[s][q][2], execSeq[s][q][1])

\* STORE STATE: each key holds the executed write with the largest OrderKey.
StoreOrder ==
    \A s \in Servers, k \in AllKeys :
        \A x \in Range(execSeq[s]) :
            k \in KeysOf(x[1]) =>
                ~OKLess(store[s][k].t, store[s][k].w, x[2], x[1])

=============================================================================
