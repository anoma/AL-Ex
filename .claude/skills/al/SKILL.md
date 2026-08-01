---
name: al
description: How the AL runtime works and how to extend it — use when working in this repo (the Elixir object-oriented Prolog / WAM interpreter over an append-only Mnesia command log). Covers the goal/choicepoint VM, event-sourced object stores, forks/branches, packages, async scheduling, and the conventions for adding goals, packages, and examples.
---

# AL

AL is an **object-oriented Prolog**: a WAM-style interpreter over an **append-only
command log** in Mnesia. Live relational objects, bidirectional execution, ACID
transactions, durable + replayable state, Git-like branching.

## Mental model (design philosophy)

- **Commitment machine.** A stack of transactional state machines, ephemeral →
  durable. The durable base is the append-only on-disk command log (authoritative
  history); upper layers (the object projection) are *derived* from it, and a
  commit cascades upward. Everything runs in a Mnesia transaction so changes are
  atomic. Distribution comes from nodes *interacting*, not sharing a log — each
  node owns its history.
- **Objects are relational, not primary.** An object *emerges* from relations
  (`vm_class(a, …)`, `vm_super(…)`, `slot value …`); the object tables are a
  materialised view of the log — which is what makes replay, forks, and (planned)
  bitemporal queries fall out for free.
- **Inheritance is just a relation** (`vm_super`), so the class graph and its search
  order are ordinary data — multiple inheritance is free.
- **Backtracking is a feature.** WAM semantics give full backtracking +
  bidirectional execution: a var in receiver position turns a `send` into a query
  the runtime searches over.

## Architecture (lib/AL)

- **`AL` (lib/AL.ex)** — the interpreter's core stepping engine:
  - `run do … end` → `AL.Lowering.ast_to_pattern` lowers surface syntax to
    `goal()` tuples → `eval/3` runs them in `:mnesia.transaction`. `run branch: b
    do … end` targets fork `b`; bare `run` uses `AL.Branch.head()`.
  - State = `%AL{active_choicepoint, choicepoint_stack, branch, tx_id, …}`.
    `continue/1` drives goals, `backtrack/1` pops the stack. Success →
    `{:atomic, {output_vars, state}}`; failure `:mnesia.abort`s → `{:aborted, trace}`.
  - `interp/2` has one clause per goal, but for whole *families* of goals that
    clause is one line delegating to the module that owns that concern — `AL`
    itself only keeps the goals with no better-named home: `Unify`/`Equal`/
    `Dif`/`Compare`/`Ground`/`IsVar`/`Freeze`/`Functor`/`CallTerm`/`Not`/`Call`/
    `Findall`/`Forall`/`Fail`, plus arithmetic (`interp_is/2`) and the
    primitive `OApply` cases (`is`, `map_get`, `map_put`, `fresh_id`,
    `current_tx`) and `OApply`'s own general clause (method dispatch — see
    below). `oapply` expands a method head into its body **bidirectionally**:
    freshen the clause's vars by scope, unify head with call args into the
    *shared* binding map, run the body; a continuation resumes the caller with
    that same map — so head-var bindings made in the body are visible to the
    caller (no copy-back). `send`/`send_query`/`send_as_value`/
    `durable_candidates`/`call_next_method` clauses delegate straight to
    `AL.Dispatch`.
  - `wake/2`, `unify/3`, `try_unify/5`, `fresh_scope/0`, `cached_scan_clauses/2`,
    `put_bindings/3`, `fan_out/3`, `scan_clauses/5`, `standardize_apart/1`,
    `splice_goals/2` are `def` (not `defp`) specifically so `AL.Dispatch`,
    `AL.Store`, `AL.Relations`, and `AL.ControlFlow` can call back into
    them — all mutually recursive with `AL` (each calls `AL.interp/2` to run
    goals it splices; `interp`'s own clauses delegate out to them), which is
    fine across modules on the BEAM. `unify/3` is the one nearly every goal
    clause wants: `AL.unify(state, x, y)` pulls `store`/`branch` off `state`
    itself, so `branch` threading for `isa` (see `AL.Var`, below) stays
    invisible at ordinary call sites.
  - Object creation is **three-phase**: `construct` (ephemeral object, e.g.
    `%{class: self}`) → `allocate` (persist / give identity) → `init` (setup).
    `new` on `:class` chains all three (AL's take on ObjVLisp allocate/initialize).
- **`AL.Lowering` (lib/AL/lowering.ex)** — `ast_to_pattern/1`: a pure, stateless
  tree transform from the `run`/`defmethod` surface syntax to `AL.Goal` structs.
  No interpreter state, doesn't call `interp`/dispatch. `AL.ast_to_pattern/1` is
  kept as a `defdelegate` so the public API and the `run` macro don't need to
  change.
- **`AL.Dispatch` (lib/AL/dispatch.ex)** — resolves a `send` into a concrete
  method application: candidate generation (structural/ephemeral/value/durable
  legs), the selector query, grounded application (`do_send`/`run_providers`),
  and DNU. See "How a `send` evaluates" below — that whole section now lives
  here. Public entry points `dispatch/5`, `do_send_as/6`, `force_durable_candidates/4`,
  `run_providers/6`, `dnu/4` are what `AL`'s `interp/2` calls into; everything
  else is private. A value candidate's `isa` pinning is attached directly to
  the choicepoint `value_candidate/5` builds, at construction — before its
  clause ever runs, so it's live for the whole call including nested sends,
  not a goal spliced to run afterward (see `AL.Var`, below, and
  al-clp-for-objects memory for why the timing has to be this way round).
  `dispatch/5` also won't offer `:number`/`:list`/`:map` as sibling candidates
  once `self` already carries one of them — they're mutually exclusive by
  construction (`shape_conflict?/2`).
- **`AL.Dispatch.MethodOrder` (lib/AL/dispatch/method_order.ex)** — the
  resolution-order topological sort (`method_scopes/2`, `super_chain/3`, Kahn's
  algorithm). Pure functions of a receiver/class and a branch, no choicepoint or
  bindings involved — the most standalone piece of the whole dispatch subsystem.
- **`AL.Continuation`/`AL.Choicepoint` (lib/AL/continuation.ex,
  lib/AL/choicepoint.ex)** — the two struct defs `AL` builds its state from;
  split out since they're pure data, no logic.
- **`AL.Store` (lib/AL/store.ex)** — the object-mutation goals: `SetClass`/
  `SetSuper`/`SetMethod`/`SetOapply`/`SetSlots` and their five `Retract*`
  counterparts. Every one writes both the durable command log (`AL.Command`)
  and the in-memory projection (`AL.Object`) through one shared `write/3`
  helper — same op name on both modules by design, so `write/3` just `apply/3`s
  it onto each. A goal whose `object` is already a live map (an ephemeral
  instance) is a no-op on all ten — ephemeral objects carry no command-log
  identity at all.
- **`AL.Relations` (lib/AL/relations.ex)** — the relational *read* goals:
  `GetClass`/`GetSuper`/`GetMethod`/`GetOapply`/`GetSlots`. Each is a scan
  through `AL.Object` fanned out over `AL.fan_out/3` (a shared `scan_relation/3`
  covers everything but `GetOapply`, which standardizes each row apart first —
  see "How a `send` evaluates" for why that matters). `GetClass` is the one
  exception to "always scan": an unbound `object` with a ground `class`
  doesn't need a witness to succeed, so it registers an `isa` constraint (see
  `AL.Var`, below) instead of touching `AL.Object` at all — see
  al-dif-constraints memory for why that's sound. The reverse direction (`object`
  unbound, `class` *also* unbound — querying self's class, not asserting it)
  has its own fast path too: if `object` already carries a known `isa` domain,
  `GetClass` answers from it directly instead of scanning a durable table an
  ephemeral/value receiver was never going to have a row in.
- **`AL.ControlFlow` (lib/AL/control_flow.ex)** — the choicepoint-stack control
  goals: `Cut`, `Implies`, `Or`, `Then`. Each is entirely about which
  alternatives stay on `state.choicepoint_stack`, never about producing a
  binding — see "Execution model: choicepoints, marks, cut" below for what
  `{:mark, scope}`/`:implies_mark` mean and why `Cut`/`Then` drop the stack
  down to one.
- **`AL.Var` (var.ex)** — unification against one unified **store**: a
  var→entry map where an entry is either a bare bound term or an
  `AL.Var.ConstraintSet{dif, isa}` struct for a still-open var carrying
  constraints — a binding is just the maximally-specific case of "what's
  known about this var," not a different kind of fact from `dif`/`isa`, and
  standard CLP theory doesn't distinguish them either. The struct (not a
  plain map) is what lets `deref/2` tell "still open, here's what's known"
  apart from "bound to a term that happens to be a plain map," with no
  wrapper needed on the bound side — no AL-level term is ever a
  `%ConstraintSet{}`, so a bare bound value and the struct are already
  unambiguous by pattern match, and a plain old-style bindings-only map
  (nothing but bound vars, no `dif`/`isa` ever used) is already a valid store
  as-is. `deref`, `subst`, `freshen`, `unify` all take this one store.
  `bind/4` runs an **occurs-check** (`occurs?/3`, cons-aware for improper
  lists `[h | $tail]`) so cyclic terms can't form, and checks the constraint
  set on a var *before* overwriting it with a bind (a bind and a
  `ConstraintSet` are the same store slot — capture-then-check, not
  check-then-overwrite, or the lookup would find nothing) — the one place a
  constraint is guaranteed to see every bind, however deep in the interpreter
  it happens, dispatch's own candidate generation included
  (`AL.Dispatch.structural_candidate` unifies through this same path).
  `dif/2` and `isa` (`add_isa/3`, `dif`'s positive counterpart — "every
  future bind must belong to `class`", not "must never equal `term`") are its
  two tenants; `isa_of/2` is the read side, letting a query answer from a
  var's known domain instead of scanning (see `AL.Relations`'s `GetClass`,
  above). Verifying `isa` needs a `branch` — `:number`/`:list`/`:map` are
  decidable from the term's own shape for free; a value class beyond those
  three is provable by matching one of its own *discriminating* clause heads
  (`AL.Dispatch.value_member?/3` — a bare-variable self position proves
  nothing and is excluded, or this would be vacuously true for anything);
  every other class is a relational fact recorded in the durable store, not a
  property of the term, so it costs one lookup of the bound term's own class
  chain (`AL.Dispatch.MethodOrder.method_scopes/2` — cheap, one object's own
  classification, not the scan generating durable *candidates* needs).
  That's the one place `AL.Var` reaches outside itself; `AL.unify/3` (in
  `AL.ex`) is the state-aware convenience every other module actually calls —
  `AL.Var.unify/4` directly only when there's no `AL` state to pull
  `store`/`branch` from (see e.g. `e_var.ex`, which relies on `branch`'s
  default). Vars are atoms starting with `$` (`:"$x"`).
- **`AL.Command` (command.ex)** — the event log. Each mutating goal writes a
  `{:command, t, tx_id, op}` row. `t` is a **global monotonic counter** shared
  across stores, so commands are globally ordered (makes cross-branch diff/merge by
  `t` well-defined).
- **`AL.Object` (object.ex)** — the projection: a RAM materialisation of the log
  (class/super/method/oapply as `:bag`, slots as `:set`). Rebuilt by replay
  (`hydrate_since`); `scan_*` query it.
- **`AL.Branch` (branch.ex)** — forks. `fork(at \\ :tip, from \\ head())` copies
  `from`'s log prefix into a new store + projection; writes diverge. Forks nest.
  `checkout` sets HEAD; `discard` tears a fork down.
- **`AL.Package` (package.ex)** — `defpackage` installs definitions as a durable
  receipt object; dependency-ordered, reversible `uninstall`. Installed at boot
  from `config :al, :packages`. `bootstrap` is foundational (class/object/method
  machinery **and** the list protocol: hd, tl, concat, reverse, map, fold, flatten,
  same_length).
- **`AL.Scheduler` (scheduler.ex)** — async. `send_async`/`send_elixir` are goals
  that only *write a command*; the scheduler reacts. **One scheduler per store**
  (`:main` + each fork) under a DynamicSupervisor, each subscribed to its own
  command table, so fork async stays on the fork. `Branch.fork`/`discard`
  start/stop it.

## Execution model: choicepoints, marks, cut

The choicepoint stack mixes real `%Choicepoint{}` alternatives with two **boundary
sentinels** marking where a scope begins, so backtracking, `cut`, and `then` know
how far to reach:

- `{:mark, scope}` — pushed by `oapply`/`call` *below* a call's alternative
  clauses; `scope` is the call's freshener and equals the new frame's
  `scope_pointer`. `:implies_mark` — pushed by `implies`. Both are **inert during
  ordinary `backtrack`** (skipped; `{:mark, f}` also emits a trace-fail).
- **`cut`** drops the stack to (not including) the `{:mark, f}` whose `f` matches
  the active frame's `scope_pointer` — committing every choice in the current
  method/call scope.
- **`implies(cond, then, else)`** runs `cond ++ [{:then, then}]` and pushes
  `[else_choicepoint, :implies_mark]`. `cond` fails → backtracking reaches the else
  choicepoint. `cond` succeeds → `{:then, _}` drops the stack down to and including
  `:implies_mark`, discarding `cond`'s remaining alternatives and the else (a soft
  cut committing to `cond`'s first solution).
- **`or`** pushes the right branch as a plain choicepoint (no mark).
- `scope_pointer` is carried in continuations, so returning from a method restores
  the caller's scope for the next `cut`.

## How a `send` evaluates

Lives in `AL.Dispatch` (+ `AL.Dispatch.MethodOrder` for resolution order); `AL`
just delegates to it from `interp/2`.

**The three candidate families (durable/ephemeral/value) answer one question
differently: does this class have a construction step whose behavior isn't
fully readable off the clause heads?** (See "Known gaps" for the domain +
labeling framing this decomposes into, and where it's headed next.)
- **Durable** — real identity; must retrieve an existing object
  (`durable_candidates`), never fabricate one.
- **Ephemeral** — has real construction behavior (`construct`/`allocate`/`init`,
  possibly with defaults/validation/side effects beyond what a clause head
  literally mentions) — must actually run `new` to get a faithful shape
  (`ephemeral_candidate`), or a hand-assumed shape risks drifting from what
  `init` really builds.
- **Value** — no construction step at all; the clause heads *are* the complete,
  authoritative spec of a valid instance (`:number`: `1`, `n`; `:list`: `[]`,
  `[h|t]` — nothing else could be true of an instance). Unifying an unbound
  `self` straight against the class's own clauses is safe precisely because
  there's no hidden constructor behavior to skip — routing an *ephemeral*
  class through this leg instead would silently fabricate instances that
  bypass `init`. `:list`'s `[]`/cons hypothesis used to be a fourth,
  hardcoded "structural" leg — folded into value (`import(:list, :value)`)
  once `:list`'s own clause heads turned out to already satisfy exactly this
  leg's requirement, with no VM-level special case needed at all.

Orthogonal to all three: an **`isa` constraint** (`AL.Var.add_isa`) pins a var
to a class the moment dispatch commits it there, even if the matched clause
leaves it open — see the value leg's `ConstrainIsa` step and al-clp-for-objects
memory for the timing subtlety that makes this sound.

1. **Lowering (`AL.Lowering.ast_to_pattern`).** `send(recv, sel, args)` and implicit
   `sel(recv, …)` (any atom head with ≥1 arg) become `{:send, recv, sel, args}`.
   Direct VM ops never become sends: arithmetic (`+ - * / **`) and
   `@oapply_primitives` (`is`, `map_get`, `map_put`, `lookup`, `fresh_id`,
   `current_tx`) lower to `{:oapply, …}`; zero-arg `foo()` → `{:oapply, foo, []}`.
2. **Pre-substitution.** `continue` substitutes the goal against bindings before
   `interp` sees it, so "var receiver/selector" means *still unbound after deref*.
3. **`dispatch/5` picks a mode** (`:send` → `on_miss = dnu`; `:send_query` →
   `on_miss = backtrack`):
   - **var receiver** (not `:"$_"`) → generative dispatch over three candidate
     kinds, each pushed as a choicepoint (current frame `Fail`s to force entry,
     LIFO try order): durable objects (`durable_candidates`, deferred behind a
     placeholder choicepoint — see `AL.Dispatch`, above — filtered by
     `answers_selector?` — not an unconditional class-table scan) → ephemeral
     classes (`ephemeral_descendants`, also selector-filtered; `new`-based
     construction for classes with declared ivars, e.g. `single`/`union`/`set`)
     → value classes (`value_descendants`, also selector-filtered; any class
     that `import`s `:value` — `:number` and `:list` in bootstrap.ex today —
     is tried directly against `self` via its own clause heads, no
     construction/retrieval at all). `AL.ResolutionCache`
     (per-branch, flush-on-write Mnesia tables) memoizes `providers/3`,
     `ephemeral_descendants/1`, `value_descendants/1`, `durable_classes/1`, and
     `answers_selector?` — all pure functions of durable state otherwise
     re-derived on every open dispatch. A var reaching the value leg gets an
     `isa` constraint pinning it to that class going forward (`AL.Var.add_isa`,
     via a `Goal.ConstrainIsa` spliced *after* the `SendAsValue` attempt, not
     before — registering it first would make the class's own first clause
     match immediately violate the constraint that same call just added, for
     any class whose clause-head literals aren't otherwise durably classified;
     deferring past the `OApply` continuation means there's nothing to check
     yet if the clause already grounded `self`, and it's sound to add if the
     clause left `self` open). See al-clp-for-objects memory.
   - **var selector** (not `:"$_"`) → query over the receiver's methods:
     `understood_method_names` walks `self` then its class/super chain (deduped); a
     choicepoint per name binds `sel`, then re-dispatches. Arg shape decides which
     matches.
   - **both ground** → `do_send`. (Both var: receiver query grounds the object
     first, then the spliced `send_query` re-enters dispatch for the selector.)
4. **`do_send`** with `call_args = [self | args]`:
   - `providers/3`: ordered `{scope, id}` pairs from `method_scopes` (map receiver
     → its `:class` key chain, default `:map`; list → `:list`; atom → itself then
     its classes/supers) crossed with `method_ids` per scope, cached per
     `(self's resolution key, selector, branch)`. `run_providers` tries them in
     order — **first clause match wins**, stashing the rest as a
     `call_next_method` cursor (no backtracking over candidates here — the query
     modes add that).
   - no candidates → `on_miss`.
   - candidate → `has_matching_clause?`: primitives `is/map_get/map_put/gensym/fresh_id`
     are allowlisted (no stored clauses — e.g. `map`'s `:get` → `:map_get`); else a
     freshened clause head must unify with `call_args`. No clause fits → next
     candidate, or `on_miss` if none left.
   - match → `{:oapply, id, call_args}` (bidirectional; a method's other clauses
     become alternative choicepoints).
5. **`on_miss`:** directed (`dnu`) re-sends as `does_not_understand(self, [sel,
   args])`, resolved like any send (default `:object` body is `:fail`); the `dnu`
   guard backtracks if `does_not_understand` itself isn't understood, so no loop.
   Query (`backtrack`) falls to the next candidate — **DNU never fires for a query.**

Edge cases: a query with no candidates fails, never DNUs; only fully-ground sends
DNU; `:"$_"` in receiver/selector is the match-anything wildcard, not a slot to
ground (falls to `do_send`, takes the first method — use a real var for a query);
of the three var-receiver candidate kinds, only durable objects require a class
row — ephemeral/value candidates are offered regardless.

## Tables

Fields key-first. Projection tables (`AL.Object`) are per-branch `ram_copies`, a
**materialised view** rebuilt by replaying `command` in `t`-order; the log +
lineage are the durable truth.

Projection (`AL.Object`):
- `class {object, class}` · `:bag` — `object` is an instance of `class` (several
  rows = multiple classification).
- `super {object, super}` · `:bag` — class `object` has superclass `super`
  (several rows = multiple inheritance).
- `slots {object, slots}` · `:set` — `object`'s slot map; one row, latest wins.
- `method {object, method_name, method_id}` · `:bag` — class/object answers
  `method_name` with method object `method_id`; resolved up the class/super chain.
- `oapply {object, seq, head, body}` · `:bag` — the **clauses** of a method:
  `object` is a `method_id`, `head` the arg pattern (`[self | …]`), `body` the goal
  list. `seq` is an explicit non-neg integer ordering key — `scan_oapply` sorts by
  it, so clause try-order is first-class data, stable across replay/fork. Surface:
  `vm_set_oapply(o, h, b)` appends (interp resolves the `:next` sentinel via
  `next_oapply_seq`); `vm_set_oapply(o, seq, h, b)` places at an explicit seq;
  `vm_clause(o, h, b)` / `vm_clause(o, seq, h, b)` read clauses (the 4-arg form
  exposes `seq`). Rearrange = retract then re-`set` at chosen seqs.

Log + metadata (`AL.Command`, durable):
- `command {t, tx_id, command}` · `:ordered_set` — the append-only log. `t` is the
  global monotonic ordering key; `command` is the op. Authoritative; all else
  derives from it.
- `meta {key, value}` · `:set` — per-branch key/value (e.g. `:head` → current
  branch, kept in `:main`'s `meta`).

Lineage (`AL.Branch`, `:main` only):
- `branch {parent, child}` · `:bag` — fork lineage edges; HEAD is `meta[:head]`.

## Stores

`:main` uses base table names; fork `f` uses `@f`-suffixed tables (`class@f`,
`command@f`, …) created with `record_name:` the base relation, so record tags and
scan patterns are identical across stores. Almost every `AL.Object`/`AL.Command`
function takes a trailing `branch \\ :main`. `AL.ResolutionCache` follows the same
per-branch naming (`al_providers_cache@f`, …) for its flush-on-write **Mnesia**
`ram_copies` tables — not ETS; a table has to outlive whichever transient process
called `AL.Branch.fork/2`, which an ETS table wouldn't (`providers/3`,
`ephemeral_descendants/1`, `value_descendants/1`, `durable_classes/1`,
`oapply_clauses/1`, `answers_selector?`'s memo) — created/dropped alongside a
branch's other tables in `AL.Branch.setup/create_fork/discard`, so a fork's
cache never leaks into `:main`'s.

## Debugging a live session

A failed `run`/`next_solution` doesn't just hand back a curated summary — the
reason map (`message`/`reason`/`failed_on`/`trace`) also carries **`state`**:
the actual final `%AL{}`, whatever store/choicepoint_stack the last attempt
left behind before the stack exhausted. `trace` tells you *which goals were
tried*; `reason.state` lets you inspect *what was true when the last one
failed* — e.g. `AL.Var.isa_of(reason.state.active_choicepoint.store, var)` for
what was still parked on a var, not just that some goal failed. Stripped back
out (`nil`) on the `heap:`-capped `eval` path (`AL.shed/1`) — that path exists
specifically to bound what crosses the process boundary, so keeping the full
state there would defeat its own purpose. Example:
`failed_run_exposes_the_final_state` in `e_AL_failures.ex`.

A `unify(a, b)` goal failing because a `dif`/`isa` constraint rejected it looks
identical to an ordinary structural mismatch in the trace alone — the next
goal just isn't there either way, no annotation of *why*. `Goal.Unify`'s
interp clause calls `AL.Var.diagnose_unify_failure/5` on a `nil` result and,
if it can explain it, records `{:constraint_violated, violation}` into
`state.diagnostics` (the same mechanism DNU/resource-limit already use), so
`reason.message`/`reason.reason` name the constraint directly instead of just
"goal failed". Deliberately scoped, not exhaustive: only covers the direct
"one side a still-open var carrying the constraint, other side already
concrete" shape (covers every constraint example in this codebase, including
the ones that motivated building this) — a var-vs-var mismatch, or a failure
from some other goal that calls `AL.unify/3` internally (`GetClass`,
`GetSuper`, method-head unification during `OApply`, …) doesn't get this
treatment yet, and returns `nil` (no diagnosis offered) rather than guessing.
Example: `unify_failure_names_the_violated_constraint` in `e_AL_failures.ex`.

`AL.Trace.call/4`/`fail/3` (`trace(:selector)`) only fire once a clause is
actually applied — they say nothing about *which candidate legs an unbound
receiver had to try* to get there. `AL.Dispatch.dispatch/5`'s var-receiver
branch calls `AL.Trace.dispatch/4` when the selector is a tracepoint, printing
the legs being offered *before* any of them run: structural (always
`[cons, []]`), `ephemeral=[...]`/`value=[...]` (the actual selector-filtered
class lists — already computed either way, free to report), and
`durable=deferred` — deliberately not a candidate count, since the durable
leg's whole point is not scanning until backtracking actually reaches it
(`AL.Dispatch.force_durable_candidates/4`); reporting a count here would force
that scan just to trace it. Example: `trace_shows_dispatch_legs` in
`e_AL_trace.ex`.

## Adding a goal

1. `ast_to_pattern/1` clause (surface syntax → goal tuple) in lib/AL/lowering.ex.
2. Add it to the `goal()` typespec.
3. `interp/2` clause, in whichever module owns that goal's concern — a plain
   mutation goes in `AL.Store`, a plain scan in `AL.Relations`, a choicepoint-
   stack goal in `AL.ControlFlow`, a dispatch goal in `AL.Dispatch`; only add a
   clause directly to `AL` itself if the goal doesn't fit any of those (and
   add a one-line delegating clause to `AL`'s own `interp/2`, matching the
   existing ones, so `continue/1` still finds it). A mutating goal must
   **both** write the command (`AL.Command.*`) **and** apply to the
   projection (`AL.Object.*`); a read/query goal scans the projection and
   pushes choicepoints via `AL.fan_out/3`.
4. If it mutates, add a case to `AL.Object.hydrate_event/3` so replay/fork works.

## Conventions

- **Weigh what a design change forecloses, not just what it enables.** Every
  mechanism in AL sits at a real tradeoff point, not a strictly-better move — ask
  what capability is being traded away before adopting a change, not just what it
  unlocks. Concrete instance: durability-by-default is AL's actual differentiator
  over Logtalk, but it's *why* ephemeral construction has to exist as a separate,
  deliberately non-durable path — removing that distinction wouldn't be a
  simplification, it would silently foreclose either cheap backtracking-driven
  generation or durability-by-default, not both. Same reasoning applies to
  `super` vs. flat `import`: `super` is *already* a live, transitive form of
  import (dispatch re-derives it fresh every call, per
  [[al-commitment-machine]]) — collapsing to "just import" doesn't eliminate a
  redundant mechanism, it silently forecloses automatic propagation to classes
  and methods defined later. When a change looks like a pure win, look for the
  capability it's quietly giving up.
- **Examples are the tests.** They live in `lib/examples/e_AL_*.ex` as ExExample
  `example` blocks, wired into `test/al_test.exs` via
  `use ExExample.ExUnit, for: Examples.X`. Run with `mix test`. Examples are
  memoised nodes — one can call another to reuse its result.
- **Examples before implementation, then sweep for edges.** Write the `example`
  first — it should be red before any implementation — then implement to green.
  Assert *observable behaviour* (what a `send`/query returns) over internal
  storage. **After** it works, add examples for the corners the implementation
  surfaced (boundary args, empty results, backtracking, cut/DNU/fork interaction,
  idempotence/replay).
- **Every bug fix ships with a test** — the *simplest* `example` that's red on the
  old code, green on the new. This is how AL pins its subtle semantics
  (unification, cut/marks, bidirectionality); a fix without a regression example is
  incomplete.
- Keep example files **topic-scoped**: `e_AL_arithmetic.ex`, `e_AL_lists.ex`,
  `e_AL_tasks.ex` (async), `e_AL_branch.ex` (forks), `e_AL_clauses.ex` (clause
  ordering), etc. When a feature outgrows `Examples.AL`'s general surface, give it
  its own file and wire a `…Test` module in `al_test.exs`.
- Test capabilities, not sugar: e.g. async tests build their receiver from
  bootstrap primitives (`defmethod`) rather than a convenience package.
- **DSL gotcha — `do…end` bodies vs `[…]` goal lists.** A method/`run` body is a
  `do…end` block (goals newline- *or* comma-separated). `forall` takes its
  condition as a `[…]` list literal (comma-separated) but its body as a
  `do…end` block: `forall([cond_goals]) do body_goals end`. `findall(t, cond,
  r)`, `not`, and `call` still take **list literals** throughout — goals must
  be **comma-separated**, else a confusing `syntax error before: <goal>`
  (Elixir list syntax, not a parser bug).
- **`implies` uses a `cond`-style `->` block** (the only form):
  ```elixir
  implies do
    [cond_goals] -> then_goals
    [more_goals] -> body      # extra clauses read as `else if`, nesting in the else
    :else -> else_goals       # optional; omitting it means an empty (failing) else
  end
  ```
  It lowers (`AL.Lowering.build_implies/1`) to nested `{:implies, cond, then, else}`. Branch
  bodies are `do`-block clauses (newline-separated), so it side-steps the comma
  gotcha. A `->` clause can't have an empty body — for an empty then-branch put the
  shared trailing goals inside each branch.
- Module docs are first-person ("I am …", "I provide …").
- **No junk comments.** Don't restate code or narrate the obvious; names and types
  carry meaning. Comment only a non-obvious *why*. Keep docstrings terse.
- Mnesia artifacts (`.mnesiastore/`, root `MnesiaCore.*`) are gitignored — never
  commit them.
- **`rm -rf .mnesiastore` to pick up a changed definition is fine.** Package
  install is idempotent by name only, so editing an already-installed package's
  source (e.g. `bootstrap.ex`) has no effect until it's reinstalled — and
  `defmethod` *accretes* a clause rather than replacing, so a buggy clause needs
  an explicit retract or `uninstall` + reinstall otherwise. Wiping the store is
  the simplest way to force that: it's gitignored/disposable, and boot
  reinstalls every package fresh from current source. A **VM-level change to
  the goal encoding** (tuple shape/arity, a new sentinel like `:next`, a
  reordered field) makes a wipe *necessary* rather than just convenient —
  old-shape goals already in the log can no longer replay (`interp/2` crashes
  with a `function_clause` on an `interp({:set_oapply, …})`-style goal of the
  wrong arity).
- Prefer a **throwaway fork** (`AL.Branch.fork` … `discard`) instead when you
  want to verify a fix without disturbing other branches'/forks' state.

## Roadmap context

README promises **bitemporality** (valid-time, not just the log's transaction-time
`t`) and easy time-travel between branch points. Forks are the groundwork;
diff/merge and valid-time queries are unbuilt.

`AL.Dispatch.MethodOrder.method_scopes/2` (the materialised resolution order) is the substrate for a future
`call_next_method`: have resolution return its position in that list and let a
`call_next_method` goal re-resolve the selector from the next scope on.

## Known gaps

- **No real arithmetic constraint propagation.** `Compare`/`vm_is` are forward-only
  (both operands must already be ground) — `factorial`'s backward clause works
  around this with a `between`-based generate-and-test, not real domain
  propagation. A `#<`/`#>`-style CLP(FD) mechanism (park a propagator when a
  side is unbound, narrow bounds, check once both are ground — same shape as
  `dif`/`isa` in `AL.Var`, but with an actual domain instead of a single
  equality/membership check) is the real fix, and is what backward-mode
  fibonacci genuinely needs. Alternative/complementary approach never built:
  represent numbers as bit-lists (LSB-first, miniKanren's `pluso`/`*o` style)
  so unification can extend them one bit at a time the way `[H|T]` does for
  lists — `+ - * / **` are `@oapply_primitives` that skip `dispatch`/`send`
  entirely today, so this would be a real `:number`/`:bits` behaviour with its
  own recursive clauses, coexisting with (not replacing) native-integer `is`.
- **The four dispatch legs are converging toward one domain-constraint
  mechanism — in progress, not finished.** Every leg answers the same
  question — "self is unbound; what's its domain of possible values, and how
  do we get a concrete one when forced (`labeling`, in CLP(FD) terms)?" —
  differing only in how the domain is represented: value/structural is a
  predicate domain ("unifies with one of class C's clause heads"), ephemeral
  is a shape domain ("a map with these keys, satisfying these invariants"),
  durable is an explicit finite set (ids read from the log). `isa` already
  stores a predicate domain (a class name, checked via `isa?/3`); the
  generalization is letting that stored domain be richer — a shape
  description, or an explicit id set — so all of them write into the same
  constraint instead of three-to-four separately-hardcoded Elixir legs.
  - **Structural folds into value with no caveats** — `:list`'s cons/`[]`
    hypothesis already *is* a value-leg case (a list's shape is its complete
    spec), kept as a hardcoded special case only because it predates
    `:value`'s existence. This is the concrete near-term step (see
    al-clp-for-objects memory for progress).
  - **Ephemeral also fully collapses, once two things are true.** (a) Its
    validation/defaults/invariants (e.g. a `union`'s left/right disjointness)
    need to be expressible as constraints, not imperative checks — this is
    exactly what `absento` (miniKanren's structural disequality: "X never
    appears anywhere inside Term", even as Term grows through still-open
    sub-parts — `dif`'s `migrate_constraints` re-attach trick, generalized to
    recurse into revealed structure) is for; not built. (b) Ephemeral
    construction must never touch anything durable or external — already
    true by construction today (`AL.Store`'s goals no-op when `object` is a
    live map; `:ephemeral`'s own `allocate`/`init` are identity), so this
    isn't a new constraint to add, just an invariant to keep honoring as
    classes gain real `init` logic.
  - **Durable does not collapse into the others — a different resource, not
    a different amount of laziness.** Its domain is real, mutable, external,
    persistent state; producing a witness (`labeling`) means an actual scan,
    can race against concurrent writers, and is the one place backtracking
    away from a tried candidate doesn't undo anything (nothing durable was
    written by a `send`'s own candidate generation) — contrast a
    non-transactional effect like `send_elixir` reaching an external
    process, which *is* the one place nothing in AL rolls back, but that's a
    property of the goal type, not of durable dispatch specifically. This
    split is exactly why the durable leg was the one to get lazy first
    (`AL.Dispatch.force_durable_candidates/4`) — it was already the odd one
    out.
  - End state: one dispatch loop asking each candidate class how it wants to
    describe its domain (an AL-level category/behaviour hook, not an Elixir
    special case per leg — consistent with "package means defpackage"),
    with durable staying the sole leg whose *labeling* is genuinely
    expensive and lazy, not because it's special-cased but because it's
    touching a different kind of resource than the other three.
- **Durable candidate generation doesn't consult `isa`/`dif` before scanning.**
  `AL.Var.bind/5` being the one choke point means a wrong-class durable
  candidate is always *rejected* correctly (see al-clp-for-objects memory),
  but `durable_candidates` still enumerates and `try_unify`s every
  selector-matching object first — an existing `isa` constraint could in
  principle narrow the scan itself, not just filter its results after the
  fact. Not built; lower priority than correctness, which is already there.
- **Tuple literal parsing gap.** `AL.Lowering.ast_to_pattern` has no case for
  reconstructing a literal 3+-element tuple from Elixir's `{:{}, meta, list}`
  quoted form — writing `{:foo, 1, 2}` directly in AL surface syntax silently
  misparses as `send(:foo, :"{}", [1, 2])` instead of a tuple literal.
  (2-tuples are unaffected — `{:a, :b}` is self-quoting in Elixir's AST, no
  `{:{}, ...}` wrapper involved.) Workaround: build 3+-tuples via
  `vm_functor` instead of writing them as literals. Not fixed.
- **Atom-identity leak.** `fresh_id`/`gensym` mint atoms (`:"#N"`); the BEAM
  never garbage-collects atoms, and replay re-mints the same ones on top of
  whatever's already live. A long-lived node doing enough object creation
  eventually approaches the ~1M atom ceiling and dies. Fix is a non-atom
  identity scheme — invasive, needs its own design pass, not started.
- **Prior art, if extending constraints further**: CLOS generic-function
  dispatch has no analogue for "hypothesize a value for an unbound receiver"
  — it presupposes arguments already have concrete runtime classes, no
  unification/backtracking underneath. Prolog has no dispatch-by-type layer
  to hook into at all — clauses already *are* the generation policy, nothing
  gates them; the problem AL solves here is self-inflicted by layering OO
  dispatch over logic search, not something plain Prolog ever faces. Closest
  real precedent: **CLP(FD) `labeling(Strategy, Vars)`** (a pluggable policy
  for how an unbound finite-domain var gets concretized — `ff`/`min`/`max`/
  `bisect`) plus attributed-variable hooks (`attr_unify_hook/2`,
  `verify_attributes/3`, `freeze/2`) for customizing what happens around a
  variable's unification.
