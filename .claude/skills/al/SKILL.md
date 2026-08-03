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
  - `wake/2`, `unify/3`, `fresh_scope/0`, `cached_scan_clauses/2`,
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
  method application: candidate generation (generative/durable legs — no
  ephemeral/value split, `generative_candidate/5` always runs the class's
  real `new`, one mechanism, no strategy argument at all), the selector
  query, grounded application (`do_send`/`run_providers`), and DNU. See "How
  a `send` evaluates" below — that whole section now lives here. Public
  entry points `dispatch/5`, `do_send_as/6`, `force_durable_candidates/4`,
  `run_providers/6`, `dnu/4` are what `AL`'s `interp/2` calls into; everything
  else is private. Every generative candidate's `isa` pinning is attached
  directly to the choicepoint `generative_candidate/5` builds, at
  construction — before its goals ever run, so it's live for the whole call
  including nested sends, not a goal spliced to run afterward (see `AL.Var`,
  below, and al-clp-for-objects memory for why the timing has to be this way
  round). `dispatch/5` also won't offer `:number`/`:list`/`:map` as sibling
  candidates once `self` already carries one of them — they're mutually
  exclusive by construction (`shape_conflict?/2`).
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
  `GetClass` answers from it directly instead of scanning a durable table a
  value receiver was never going to have a row in.
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

**Two candidate families, not three — there is no `:ephemeral`/`:value`
strategy split anymore.** `generative_candidate/5` always runs the same
recipe regardless of class: call the class's real `new` (fresh vars for its
declared ivars), unify `self` with whatever `new` produces, then
`SendAsValue` the actual requested method against `self`. Whether that
leaves `self` genuinely open (for value-leg-style clause matching, e.g.
`:number`'s `factorial`, `:letter_chain`'s literal clauses) or grounds it to
a real constructed map (e.g. `:interval`, `:square`) depends entirely on
whether the class's own `:init` discards the constructed scaffold or builds
something real — `:value`'s default `:init` (bootstrap.ex) is what makes the
"stays open" case happen, not a VM-level branch. So a class opts into being a
generative candidate at all just by declaring `super: :value`
(`generative_descendants/1` scans exactly that), and what its instances look
like afterward is entirely up to its own `:init`, not a strategy flag chosen
at dispatch time.
- **Durable** — real identity; must retrieve an existing object
  (`durable_candidates`), never fabricate one. Stays genuinely separate from
  the generative leg below (a different resource, not a construction
  strategy).
- **Generative** (any `super: :value` class) — always constructs via the
  class's real `new`, so there's never a hand-assumed shape that could drift
  from what `init` actually builds. `:list`'s `[]`/cons hypothesis used to be
  a fourth, hardcoded "structural" leg — folded into this one mechanism
  (`import(:list, :value)`) once `:list`'s own clause heads turned out to
  already satisfy exactly this leg's requirement, no VM-level special case
  needed.

**Correct usage, not a VM constraint but a real convention this repo learned
the hard way:** a value class's instances should be a self-describing map
(a `:class` field, like `:interval`/`:square`/`:card` — works as both a
ground and an open receiver for free, since `Goal.GetClass`'s `is_map`
clause reads the class straight off the map, no durable lookup either way)
or left as a constrained-but-open var (`isa`, or the `in_domain/2` constraint
— see "Tables"/Conventions below), not bound to a bare atom unless that atom
is *also* durably classified. A bare atom only gets symmetric dispatch
through the durable class/super graph — `next(x, :b)` finding `x = :a` via
`:letter_chain`'s literal clauses works (generative leg, no durable identity
needed at all), but `next(:a, y)` fails with `does_not_understand`, because
ground dispatch on a plain atom only ever consults the durable graph, never
a value class's own clause heads, and `:a` was never durably classified.
Durably classifying it too (the fix that looks obvious) creates a second,
independent proof of membership alongside the generative one, so `findall`
reports every fact twice, one per leg. Don't chase that fix — use a map, or
don't materialize a bare atom at all.

An **`isa` constraint** (`AL.Var.add_isa`) pins a var to a class the moment a
generative candidate's choicepoint is *constructed* — before any of its own
goals run, even if the matched clause leaves the var open. Registering it
that early (not after the match, as an earlier version of this did) is sound
because the isa violation check only ever fires on a bind to a *concrete*
term: a clause that leaves `self` open (`:number`'s backward-search
`factorial`, `:object`'s inherited `:examine`) never trips it during its own
match, and a clause that *does* ground `self` to one of the class's own
literals (`:letter_chain`'s `:a`/`:b`) is accepted by `AL.Var.isa?/3` as
membership evidence for a value class, so it doesn't self-violate the
constraint it's the proof of — see al-clp-for-objects memory for the two
wrong turns before landing here. `dispatch/5` also won't offer
`:number`/`:list`/`:map` as sibling candidates once `self` already carries
one of them — they're mutually exclusive by construction
(`shape_conflict?/2`).

1. **Lowering (`AL.Lowering.ast_to_pattern`).** `send(recv, sel, args)` and implicit
   `sel(recv, …)` (any atom head with ≥1 arg) become `{:send, recv, sel, args}`.
   Direct VM ops never become sends: arithmetic (`+ - * / **`) and
   `@oapply_primitives` (`is`, `map_get`, `map_put`, `lookup`, `fresh_id`,
   `current_tx`) lower to `{:oapply, …}`; zero-arg `foo()` → `{:oapply, foo, []}`.
2. **Pre-substitution.** `continue` substitutes the goal against bindings before
   `interp` sees it, so "var receiver/selector" means *still unbound after deref*.
3. **`dispatch/5` picks a mode** (`:send` → `on_miss = dnu`; `:send_query` →
   `on_miss = backtrack`):
   - **var receiver** (not `:"$_"`) → generative dispatch over two candidate
     kinds, each pushed as a choicepoint (current frame `Fail`s to force
     entry, LIFO try order — generative candidates are pushed *after* the
     durable placeholder, so they're tried first): `generative_descendants/1`
     scans every class with `super: :value`, `filter_by_selector` prunes to
     ones that actually answer the selector, `shape_conflict?` drops
     `:number`/`:list`/`:map` siblings once `self`'s `known_shape` already
     picked one — each survivor becomes a `generative_candidate/5`
     choicepoint (always: real `new`, unify `self` with the result,
     `SendAsValue` the requested method). Durable objects
     (`durable_candidates`, deferred behind a placeholder choicepoint — see
     `AL.Dispatch`, above — filtered by `answers_selector?`, not an
     unconditional class-table scan) are tried last, only if backtracking
     gets that far. `AL.ResolutionCache` (per-branch, flush-on-write Mnesia
     tables) memoizes `providers/3`, `generative_descendants/1`,
     `durable_classes/1`, and `answers_selector?` — all pure functions of
     durable state otherwise re-derived on every open dispatch. Every
     generative candidate gets an `isa` constraint pinning `self` to that
     class attached to its own choicepoint at construction, before any of its
     goals run (`AL.Var.add_isa`); see al-clp-for-objects memory for why the
     timing has to be this early (not after the match, which an earlier
     version did) without breaking a value class's own literal-clause
     matches.
   - **var selector** (not `:"$_"`) → query over the receiver's methods:
     `understood_method_names` walks `self` then its class/super chain (deduped); a
     choicepoint per name binds `sel`, then re-dispatches. Arg shape decides which
     matches.
   - **both ground** → `do_send`. (Both var: receiver query grounds the object
     first, then the spliced `send_query` re-enters dispatch for the selector.)
4. **`do_send`** with `call_args = [self | args]`:
   - `providers/3`: ordered `{scope, id}` pairs from `method_scopes` (map receiver
     → its `:class` key chain, default `:map`; list → `:list`; atom → itself then
     its classes/supers — **except** when the atom's own class is
     `:class`/`:category`/`:behaviour`, i.e. the receiver *is itself* a class
     object: then "itself" is dropped from the scope and only its
     classes/supers are searched, `AL.Dispatch.MethodOrder.method_scopes/2`.
     Consequence: a method `defmethod`'d directly onto a plain class (`:coins`,
     say) is never reachable by sending to `:coins` itself — dispatch a
     singleton *instance* of that class instead, or define genuinely universal
     methods on `:object` the way `between`/`does_not_understand` do) crossed
     with `method_ids` per scope, cached per `(self's resolution key, selector,
     branch)`. `run_providers` tries them in order — **first clause match
     wins**, stashing the rest as a `call_next_method` cursor (no backtracking
     over candidates here — the query modes add that).
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
of the two var-receiver candidate kinds, only durable objects require a class
row — generative candidates are offered regardless.

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
`generative_descendants/2`, `durable_classes/1`,
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
branch calls `AL.Trace.dispatch/3` when the selector is a tracepoint, printing
the legs being offered *before* any of them run: `value=[...]` (the actual
selector-filtered `super: :value` class list, already computed either way,
free to report) and `durable=deferred` — deliberately not a candidate count,
since the durable leg's whole point is not scanning until backtracking
actually reaches it (`AL.Dispatch.force_durable_candidates/4`); reporting a
count here would force that scan just to trace it. Example:
`trace_shows_dispatch_legs` in `e_AL_trace.ex`.

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
  over Logtalk, but it's *why* generative construction has to exist as a
  separate, deliberately non-durable path — removing that distinction
  wouldn't be a simplification, it would silently foreclose either cheap
  backtracking-driven generation or durability-by-default, not both. Same
  reasoning applies to
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
    :else -> else_goals       # optional; omitting it splices an *empty* goal list
  end
  ```
  **Omitting `:else` is a vacuous success, not a failure** — `AL.ControlFlow`'s
  `Implies` splices `otherwise` as-is, and `continue/1` treats a choicepoint with
  `goals == []` as a solved goal (nothing left to run), same as any other
  emptied-out goal list. If every `->` condition fails and there's no explicit
  `:else`, the whole `implies` still *succeeds*, leaving whatever vars the
  `then` branches would have bound untouched — surprising the first time,
  since "no branch matched" reads like it should fail. Write `:else -> fail`
  explicitly whenever "nothing matched" is meant to be a failure (bootstrap.ex's
  `factorial_search`/`fibonacci_search` are the reference example — this bit
  the first version of both).
  It lowers (`AL.Lowering.build_implies/1`) to nested `{:implies, cond, then, else}`. Branch
  bodies are `do`-block clauses (newline-separated), so it side-steps the comma
  gotcha. A `->` clause can't have an empty body — for an empty then-branch put the
  shared trailing goals inside each branch.
- **`defclass name, metaclass: :class (default), super: (required), ivars: [] (default), categories: [] (default) do ... end`**
  bundles `new(metaclass, %{name:, super:, ivars:}, _)` + one `import` per
  category + one `defmethod` per method into a single `:defclass` OApply
  (bootstrap.ex). Methods inside use the 2-arg `defmethod(name, head) do body
  end` shorthand (no class prefix), always with an explicit `do...end` even
  when empty — the bodyless 3-arg `defmethod(class, name, head)` fallback
  does not apply inside `defclass`.
  - **Gotcha: two methods-list entries can't share a selector.** `:defclass`'s
    own oapply retracts *all* existing `(name, method_name)` ids before each
    `defmethod` call in the list — so a class with two same-selector entries
    (any arity) has the second retract wipe out the first's fresh clause.
    Multi-clause/multi-arity selectors (recursive methods, arity-based
    overloads) must stay outside the block as plain top-level
    `defmethod(class, name, head) do ... end` calls; single-clause methods
    for the same class can still live inside `defclass` alongside them.
  - **`metaclass: :category`** declares a category (`e_AL_categories.ex`) the
    same way — `defclass :name, metaclass: :category, super: :object do
    defmethod(...) end`. `super`/`ivars` end up as harmless unused keys in
    the category instance's construction args.
  - **`categories: [...]`** on an ordinary class bundles the `import` calls
    that would otherwise follow `new(:class, ...)` by hand — no need to
    declare the class first and `import` separately.
  - `new(class, output)` — 2-arg shorthand for `:class`'s 3-arg `new`, empty
    args (`bootstrap.ex`, coexists with the 3-arg form by arity alone). An
    `:init` method's head is always the 3-arg `[self, args, new]` shape
    regardless of which `new` arity the caller used, since `new/2` just
    delegates to `new/3`.
- Module docs are first-person ("I am …", "I provide …").
- **No junk comments.** Don't restate code or narrate the obvious; names and types
  carry meaning. Comment only a non-obvious *why*. Keep docstrings terse.
- Mnesia artifacts (`.mnesiastore/`, root `MnesiaCore.*`) are gitignored — never
  commit them.
- Mnesia store is a **shared, gitignored file** (`.mnesiastore/` by default,
  one directory per node — see below) — `rm -rf`ing it is a genuinely
  destructive, process-wide operation, not a branch-scoped one, and will
  pull the store out from under *any other node currently running against
  it* (verified: two independent `mix run` processes sharing a store, each
  only touching its own fork, don't conflict at all — the wipe itself is
  the only thing that's actually unsafe). **Default to a throwaway fork**
  (`AL.Branch.fork()` … `checkout` … `discard`) instead of touching `:main`
  directly, whenever more than one person/process might be using the same
  checkout — see the README's "Working with multiple people" section for
  the concrete workflow, `mix al.reset` for the rare genuine-full-reset
  case, and [[al-fork-practice]] for the fuller story (a wrong claim I made
  and had to retract after the user pushed back and I actually tested it).
- **Getting a changed definition picked up, three ways, cheapest-safe first:**
  1. **A fork with a fresh install, no wipe at all**: package install is
     idempotent by name only, so editing an already-installed package's
     source (e.g. `bootstrap.ex`) has no effect on an *existing* branch until
     it's reinstalled — and `defmethod` *accretes* a clause rather than
     replacing, so even an explicit reinstall on the same branch needs an
     `uninstall` first, which can fail outright for a foundational package
     with dependents (`AL.Package.uninstall(:bootstrap)` refuses if anything
     else installed depends on it — true of `:bootstrap` itself). Sidestep
     all of that by forking from **before anything's installed** instead of
     an existing branch: `AL.Branch.fork(0, AL.Branch.main())` (a fork only
     copies whatever's already in its source's log — `at: 0` means "copy
     nothing," a genuinely empty branch), checkout it, then
     `AL.Package.install_all(Application.get_env(:al, :packages))` installs
     every package fresh from *currently compiled* source. Verified
     `:main`'s own state is untouched before/after.
  2. **`mix al.reset`** (`--yes` to skip the confirmation prompt) when a
     fork genuinely isn't enough — coordinate first if anyone else might
     have a node up, since this wipes the *whole* store, every branch on it.
  3. A **VM-level change to the goal encoding** (tuple shape/arity, a new
     sentinel like `:next`, a reordered field) makes a full wipe (2)
     *necessary* rather than just convenient, even for (1) — old-shape goals
     already in *any* branch's log, empty forks included, can no longer
     replay (`interp/2` crashes with a `function_clause` on an
     `interp({:set_oapply, …})`-style goal of the wrong arity).
- **The store directory itself is configurable**, three ways checked in
  order, for when full filesystem-level separation between nodes is wanted
  (not needed for normal fork-based collaboration, but there for CI or
  wanting zero shared state on principle): `config :al, mnesia_dir: "..."`
  (persistent, e.g. a personal gitignored `config/dev.exs`) → the
  `AL_MNESIA_DIR` env var (`AL_MNESIA_DIR=/tmp/foo mix test`, no config file
  needed) → `.mnesiastore/` in the cwd, the default. Single source of truth:
  `AL.Command.mnesia_dir/0`, which `setup/0` and `mix al.reset` both read.
- **A map-shaped value class's `:init` must `unify` its output with a
  freshly literal-constructed map, not `set_slot`/`vm_set_slots` the input
  scaffold** (`:interval`'s own `:init`, `AL/package/interval.ex`, is the
  reference pattern). Durable objects can `set_slot` because `self` is a
  stable atom id and slots live in a separate keyed table — growing them is
  just another row. A map-shaped `self` *is* the map itself, already a
  concrete value by the time `:init` runs; `set_slot`/`vm_set_slots` on it
  routes through durable `SetSlots` semantics and silently does nothing
  observable to the actual returned instance. Build the whole map and
  `unify(new, %{class: ..., ...})` instead.
- **A relation used by foundational/early bootstrap code must not depend on
  another class's method defined later in the same file.** `:object`'s
  `:import` used to walk its copied-methods list via
  `forall([member(pairs, [name, id])])` — `member` isn't a VM primitive, it's
  `:list`'s own method (`vm_set_method(:list, :member, :list_member)`,
  defined ~200 lines later in `bootstrap.ex`). Any `import(..., category)`
  call earlier than that point had the `member` send silently DNU-fail
  inside `findall`/`forall`, indistinguishable from `pairs` genuinely being
  empty — masked for as long as every early-imported category actually *was*
  empty, which stopped being true the day `:value` gained real
  `allocate`/`init`. Fixed by giving `:import` a self-contained recursive
  `copy_methods` helper (`:object`) instead of leaning on `:list`. General
  lesson: a silent-failure send (DNU inside a `findall`/`forall`/`not`) reads
  identically to "no results," so a missing-provider bug at one of those call
  sites won't show up as an error — it shows up as an empty answer that looks
  legitimate until something expects a non-empty one.

## Roadmap context

README promises **bitemporality** (valid-time, not just the log's transaction-time
`t`) and easy time-travel between branch points. Forks are the groundwork;
diff/merge and valid-time queries are unbuilt.

`AL.Dispatch.MethodOrder.method_scopes/2` (the materialised resolution order) is the substrate for a future
`call_next_method`: have resolution return its position in that list and let a
`call_next_method` goal re-resolve the selector from the next scope on.

## Known gaps

- **Arithmetic bounds consistency landed for `< > <= >=`** — no separate
  `#<`-style dialect; the same operators do double duty. Both sides ground
  (via `interp_is/2`, so compound expressions like `2 + 3 <= 5` still work) is
  the original ground-only check; a side that derefs to a bare open var
  narrows an interval instead of failing (`AL.Var.add_compare/5`), the same
  `ConstraintSet` slot `dif`/`isa` already live in (`bounds :: {lo, hi}`, `nil`
  = unbounded each side) with its own `props` list of parked propagators.
  Narrowing one var re-queues every *other* propagator parked on it — a
  worklist fixpoint (`AL.Var.run_fixpoint/3`), not a one-shot check — so a
  chain (`x < y, y < 5`) tightens `x` transitively. A var whose bounds
  collapse to a single value is bound outright through the existing `bind/4`
  (so a `dif`/`isa` obligation on it is still checked), not left as a width-1
  interval nothing else would recognise as ground. A comparison against a
  non-numeric ground atom (`y > :not_a_number`) still hard-fails — only a
  number-or-open-var pair has an interval to narrow; a *ground* compound
  expression (`x < 5 + 1`) resolves fine on either side (each side prefers
  its own `interp_is` result before falling back to a bare deref), but a
  compound expression with an open var still buried inside it after
  `interp_is` (e.g. `n - 1` with `n` open) has no interval to narrow either
  and still hard-fails, same as `is/2` always has.

  **`vm_label/1`** (`Goal.Label`) is the companion CLP(FD)-labeling
  primitive this makes possible: a no-op on an already-ground term, a hard
  fail if the domain isn't bounded on both sides (nothing finite to
  enumerate), otherwise it enumerates a still-open var's propagated
  `{lo, hi}` (via `AL.Var.bounds_of/2`) — but by *splicing a `between/4`
  send* (`:object`'s own existing recursive method), not `AL.fan_out/3`.
  `fan_out` builds every alternative eagerly (`Enum.map` over the whole
  range immediately), fine for a handful of candidates but catastrophic for
  a wide domain; `between` is an ordinary recursive AL method, so — same as
  any other recursive dispatch — each next candidate only gets computed if
  backtracking actually reaches that clause. This matters in practice, not
  just in theory: `factorial`'s `n <= factorial` bound is sound but loose
  (n is really O(log F)), so `factorial(n, 3628800)` labels over a ~3.6M-wide
  domain — `fan_out` would try to eagerly materialize all of it; delegating
  to `between` finds `n = 10` in ~10ms, only ever computing the candidates
  backtracking actually visits.

  `factorial`/`fibonacci` (`bootstrap.ex`) collapse to **one relational
  clause each** on top of this — no `vm_ground(n)`/`not [vm_ground(n)]` mode
  split: the inequalities are real invariants (`n <= factorial`, sound
  because `n! >= n`), posted while `n` may still be fully open, then
  `vm_label(n)` is the single point concreteness gets forced either way.
  Forward calls hit it already-ground (no-op); backward calls hit it with a
  propagated interval to search. `fibonacci` needs one extra wrinkle: its
  sound bound is `n <= x + 1`, but `x` is exactly what's unknown in forward
  mode, so that one derivation is wrapped in `implies` and deliberately
  relies on the omitted-`:else`-is-vacuous-success behaviour (see below) —
  no bound to add is fine, not a reason to fail. Standalone propagator
  examples in `e_AL_bounds.ex`; see [[al-bounds-consistency]] for the full
  design history, including a real bug hit along the way (`implies`'s
  omitted `:else` is a vacuous *success*, not a failure — see this doc's
  `implies` section, and note fibonacci's bound derivation above
  deliberately *relies* on that same behaviour once it was understood).
  Compound arithmetic bounds (real interval arithmetic through `+ - * /`,
  narrowing a var buried inside an expression tree rather than just
  resolving a fully-ground expression) is still unbuilt. Alternative/complementary
  approach never built: represent numbers as bit-lists (LSB-first,
  miniKanren's `pluso`/`*o` style) so unification can extend them one bit at a
  time the way `[H|T]` does for lists — `+ - * / **` are `@oapply_primitives`
  that skip `dispatch`/`send` entirely today, so this would be a real
  `:number`/`:bits` behaviour with its own recursive clauses, coexisting with
  (not replacing) native-integer `is`.
- **`in_domain/2`** — "this var is one of these", a real constraint (a
  fourth `ConstraintSet` field, `domain :: MapSet.t() | nil`, alongside
  `dif`/`isa`/`bounds`) rather than a class with a `:domain` method.
  `AL.Var.add_domain/3` intersects across repeated posts the same way bounds
  narrow across repeated compares; `find_violation/4` checks it at bind time
  the same as the other three, so `unify(x, :not_in_the_set)` correctly fails
  for a domain-constrained var. `vm_label`'s fallback chain
  (`Goal.Label`'s interp) gained a tier for it, between numeric bounds and
  the class-`:domain`-method fallback: no class or `SendAsValue` involved at
  all, just `member/2` over the narrowed set. Deliberately *not* eager
  cross-narrowing with `dif` (posting `dif(x, :a)` doesn't proactively shrink
  an existing domain constraint) — labeling enumerates candidates via
  ordinary backtracking, and each one still passes through the normal
  bind-time check, so a `dif`'d value gets skipped there instead; sound, just
  not maximally tight. Built specifically to replace the
  `super: :value` + `:domain` method + one bodyless clause per literal atom
  pattern (`:suit`/`:card_rank`/`:letter_chain`) for the common case where
  the "enum" doesn't need any actual per-instance behavior — see the
  map-wrapper-vs-bare-atom convention above for why that pattern has a real,
  hard-to-notice asymmetry bug (`next(:a, y)` fails ground dispatch even
  though `next(x, :b)` finds `x = :a` fine) that `in_domain` sidesteps
  entirely, since it never involves a class or dispatch either direction.
  Examples in `e_AL_in_domain.ex`.

  **Prefer non-atom domain values where practical, even though `in_domain`
  has no dispatch-level duplication risk.** Unlike the value-class case,
  nothing about `in_domain` scans the durable graph or registers a global
  candidate, so an atom used as a domain value can't create the "findall
  reports it twice" bug even if that same atom happens to be a real durable
  object elsewhere. But "see a bare atom, know it's durable" is a real,
  useful invariant elsewhere in AL, and a bare atom sitting in an
  `in_domain` result quietly breaks it with nothing marking the difference —
  `examine(:two, info)` on an `in_domain`-only symbol returns nothing,
  which reads as broken rather than "this was never durable to begin
  with." Prefer a tagged/map shape for domain values when the domain is
  conceptually closer to "real things" than "plain symbols" (the way
  `:square`/`:card` already are), reserving bare-atom domain values for
  cases as unambiguously symbolic as `:hearts`/`:diamonds` always were.
- **Ivar specs — `defclass`'s `ivars:` can carry a per-ivar `domain:`/`type:`
  spec, and `:value`'s default `:init` wires both checking and generation
  from it automatically, no hand-written `:init` needed for the common
  case.** `ivars: [suit: [domain: [:hearts, :diamonds, :clubs, :spades]]]`
  (mixed with plain bare-name ivars is fine, e.g. `[:name, suit: [domain:
  [...]]]`) — `domain:` posts `in_domain` on the field (validated
  immediately if the caller supplies it, left open-but-domain-constrained if
  not, ready for `unify`/`vm_label` later); `type:` attaches `isa` instead/
  alongside so `vm_label`'s class-`:domain`-method fallback tier can
  generate a value for it. Zero VM changes — `ivars` was already opaque,
  already-stored class metadata, and a keyword-shaped ivar entry already
  lowers through `ast_to_pattern` unchanged (keyword-list 2-tuples are
  self-quoting in Elixir's AST like any other list literal). New methods
  live on `:object`, not `:map` — a *classed* map (a constructed value
  instance, `%{class: :card, ...}`) dispatches via its own `:class` field as
  the `method_scopes` seed, which never passes through `:map` at all
  (`:map` and `:value` are siblings under `:object`, not
  ancestor/descendant); `:object` is the one place reachable from both a
  raw classless args map and any classed instance. `ivars: []` (every value
  class that predates this) keeps its exact old default-`:init` behavior —
  the new "build from ivars" branch only ever fires for a class with
  non-empty ivars and no `:init` override, a combination with zero existing
  users before this feature. Decomposing a `{name, opts}` ivar entry uses
  `vm_functor` (a real, deterministic decompose), not a bare-var fallback
  clause after a tuple-specific one — the fallback would still structurally
  unify with a real tuple too and silently win some of the time; see
  [[feedback-prolog-clause-selection-not-elixir]]. Explicitly deferred:
  numeric-range generation, and the same wiring for durable (`:object`-super)
  classes, whose construction writes slots via Mnesia rather than an
  ephemeral map. Demo in `lib/AL/package/blackjack.ex`'s `:card`, regression
  examples in `e_AL_blackjack.ex`.
- **The dispatch legs converged to one domain-constraint mechanism —
  mechanically done, semantically still in progress.** Every leg answers the
  same question — "self is unbound; what's its domain of possible values,
  and how do we get a concrete one when forced (`labeling`, in CLP(FD)
  terms)?" — differing only in how the domain is represented: a generative
  (`super: :value`) class is a predicate domain ("unifies with one of class
  C's clause heads, or with whatever its own `new`/`init` actually builds"),
  durable is an explicit finite set (ids read from the log), and `in_domain/2`
  (`AL.Var.ConstraintSet`'s `domain` field) is now a third, explicit-set
  domain living directly on the var itself, no class involved at all — the
  generalization this section used to describe as "not built" for isa. `isa`
  stores a predicate domain (a class name, checked via `isa?/3`); `in_domain`
  is the richer case that follows from it, an explicit value set rather than
  a class-membership predicate.
  - **Structural folded into the generative leg with no caveats** — `:list`'s
    cons/`[]` hypothesis *is* a generative case (a list's shape is its
    complete spec); the hardcoded special case predating `:value`'s
    existence is gone.
  - **No `:ephemeral`/`:value` strategy split at all anymore — fully
    merged, not just sharing a mechanism.** `AL.Dispatch.generative_candidate/5`
    always calls the class's real `new` (`construct`/`allocate`/`init`), then
    reaches the method via `send_as_value` — there is no strategy argument,
    no second code path. Whether the resulting `self` stays open (ready for
    `send_as_value` to unify directly against the class's own clause heads,
    e.g. `:number`/`:letter_chain`) or comes back a real constructed map
    (e.g. `:interval`/`:mapset`) is entirely up to whether the class's own
    `:init` discards the constructed scaffold or keeps it — `:value`'s
    default `:init` (bootstrap.ex) is what makes the "stays open" case
    happen, not a VM-level branch. This replaced what used to be two
    parallel candidate-builders, two parallel descendant scans, and two
    `ResolutionCache` relations (now one `generative_descendants/1`, since
    `AL.Object`'s writers always invalidated both together anyway — they
    were never actually independent caches). A value class's `new`/`init`
    can still be overridden per-class with real logic (narrowing/rejecting
    during construction, not just at the end) if a concrete need shows up —
    not built, since no current value class needs it, but the mechanism
    doesn't block it.
  - **Semantic collapse for classes with real construction logic is still
    open**: validation/defaults/invariants (e.g. a `union`'s left/right
    disjointness) need to be expressible as constraints, not imperative
    checks — this is exactly what `absento` (miniKanren's structural
    disequality: "X never appears anywhere inside Term", even as Term grows
    through still-open sub-parts — `dif`'s `migrate_constraints` re-attach
    trick, generalized to recurse into revealed structure) is for; not
    built. A generative candidate's construction already never touches
    anything durable or external (`AL.Store`'s goals no-op when `object` is
    a live map) — an invariant to keep honoring as classes gain real `init`
    logic, not something `absento` needs to newly establish.
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
    touching a different kind of resource than the other two. Sharper
    framing: durable vs. generative isn't two kinds of thing, it's one
    mechanism with two orthogonal strategies plugged in — an *allocation*
    strategy (how a new instance comes to exist: durable writes the log and
    mints an identity; generative constructs in-memory, possibly staying
    open) and a *domain-read* strategy (how existing candidates get
    enumerated: durable scans the log; generative tries the class's own
    clause heads, or, for `in_domain`, a fixed literal set). Once both axes
    are just parameters of the same mechanism rather than two dispatch legs,
    the double-proof conflict below isn't a special case to guard against,
    it's what happens when the same var's domain gets computed by two
    different strategies at once instead of one.
  - **Concrete motivating case, found this session, now closed two ways**: a
    bare atom durably classified into a `super: :value` class whose own
    clause literally matches it (`vm_set_class(:two, :card_rank)` where
    `:card_rank` has `defmethod(:two, [:two])`) is reachable both as a
    durable object *and* as a generative candidate for the exact same fact
    — `findall` reports it twice, one proof per leg. Two guards now catch
    this, at two different points: `AL.Store`'s `SetClass` interp still
    rejects the combination at *classification* time (`vm_set_class`, via
    `AL.Dispatch.value_member?/3`), and `Goal.AssertValidClauseSelf` (native
    check, `AL.Store`, called only from `:defmethod`'s own accretion body in
    `bootstrap.ex`) rejects it even earlier, at *definition* time — a
    `super: :value` class can no longer define a clause with a bare atom as
    its self-pattern at all, so the ambiguous atom is never created in the
    first place. Neither is a general-purpose primitive; both are narrowly
    scoped to this one shape (bare atom self on a value class). The
    *principled* fix is still the unification above: if durable candidacy
    were expressed as a lazily-computed domain (same `ConstraintSet.domain`
    slot `in_domain/2` already uses, just computed from a durable scan
    instead of a fixed literal set), a var would have *one* domain, not two
    independent legs that can coincidentally agree on the same fact — the
    conflict dissolves structurally instead of needing a guard to catch it.
    `send`'s agnosticism about *which candidate kind will pan out* during
    search isn't the problem (that's ordinary backtracking, same as Prolog
    not knowing in advance which clause will match) — once something is
    concrete, durable or generative, it's never ambiguous; the guards exist
    for the narrower case of one *fact* being provable twice, not one
    *object* being unclear what it is. Explicitly deferred, not today's
    problem: a richer model where one Elixir datatype could belong to
    multiple possible classes — rejected as too complex and not performant
    enough to be worth it now.
  - **A durable atom has exactly one direct class** — `AL.Store`'s `SetClass`
    interp also rejects reclassifying an atom that already carries a
    *different* direct class (`direct_classes/2`, via
    `AL.Object.scan_class/3`); `vm_retract_class` first if the reclassify is
    intentional. Supers/inheritance (`vm_set_super`) stay a free-form,
    unrestricted DAG — this only constrains an object's own class row, not
    its ancestry. Building this surfaced a real, previously-unresolved bug:
    `AL.Package`'s `defpackage` macro creates a durable receipt object via
    `new(:package, %{name: ...}, _)`, and `:object`'s default `:allocate`
    uses `args[:name]` as the durable identity — so a package whose main
    class shares its own name (a natural, common pattern) durably classifies
    the *same atom* as both `:package` (the receipt) and `:class` (the class
    declaration). Fixed by renaming the colliding class in each affected
    package (`elixir_process`, `interval`, `sudoku`, `mapset`, `equations`),
    not by changing `defpackage`'s own receipt mechanism — simpler for now,
    though it doesn't automatically prevent the same collision in a future
    package.
  - **The durable and generative legs' requery step is now one shared
    helper**, not two hardcoded paths chosen up front by which leg you're
    in. `AL.Dispatch.requery_goals/4` splices an `Implies`/`IsVar` fragment
    that checks, *after* construction goals actually run, whether `self` is
    still open — open routes to `SendAsValue`, ground routes to `SendQuery`.
    This has to be a goal-level check, not an eager Elixir-level branch: for
    the generative leg, `new`/`Unify` haven't run yet at the point the
    requery goals are spliced in, so `self` always still looks like a var to
    an eager check regardless of which leg is running. For the durable leg
    (`force_durable_candidates`/`structural_candidate`), unification is
    eager, so by the time this runs `self` is already ground and the
    `IsVar` check is a no-op — same shared helper either way, no special
    casing. This replaced what used to be a hardcoded `SendAsValue` in one
    leg and a hardcoded `SendQuery` in the other. An earlier, more ambitious
    version of this unification effort (a new `vm_class_instances`/
    `Goal.ClassInstances` primitive, meant to make durable candidacy an
    overridable AL-level `:instances` method alongside generative's) was
    built, then fully reverted — it introduced a second primitive
    confusingly similar to `vm_class`, working against the goal of
    converging on fewer primitives, not more. `vm_class` stays the one lazy
    entry point it always was: register `isa` eagerly, defer the real scan
    until dispatch actually needs a witness.
- **Durable candidate generation doesn't consult `isa`/`dif` before scanning.**
  `AL.Var.bind/4` being the one choke point means a wrong-class durable
  candidate is always *rejected* correctly (see al-clp-for-objects memory),
  but `durable_candidates` still enumerates and unifies every
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
