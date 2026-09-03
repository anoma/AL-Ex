---
name: al-internals
description: How AL's own interpreter/VM works — the goal/choicepoint engine, dispatch resolution, unification store, event-sourced object projection, and the domino tracing model. Use when modifying AL's own interpreter code (lib/AL.ex, lib/AL/interp/, lib/AL/dispatch/, lib/AL/var/, lib/AL/durable/, lib/AL/trace/) or adding a new goal/primitive. For writing AL programs against the existing language (defclass, packages, examples, DSL gotchas), use al-practices instead.
---

# AL internals

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
- **Weigh what a design change forecloses, not just what it enables.** Every
  mechanism here sits at a real tradeoff point, not a strictly-better move — ask
  what capability is being traded away before adopting a change. Durability-by-
  default is AL's actual differentiator over Logtalk, but it's *why* generative
  construction has to exist as a separate, deliberately non-durable path —
  collapsing that distinction would silently foreclose either cheap
  backtracking-driven generation or durability-by-default, not both. Same
  reasoning applies to `super` vs. flat `import`: `super` is already a live,
  transitive form of import (dispatch re-derives it fresh every call) —
  "just import" would forecloses automatic propagation to classes/methods
  defined later.

## Architectural concerns

Five separable concerns, not a layered stack — several have no dependency on
each other at all, only on the command log itself:

- **Command log** (`AL.Command`, `lib/AL/durable/command.ex`) — the
  append-only `{:command, t, tx_id, op}` Mnesia log. The one thing everything
  else either derives from or reacts to. Depends on nothing else here.
- **Views** (`AL.Object`, `AL.SourceStore`, `lib/AL/durable/object.ex`,
  `lib/AL/trace/source.ex`) — materialised projections rebuilt by replaying
  the command log (`hydrate_since`/`hydrate_event`). Depend on the command
  log for what to project; nothing else depends on them *existing* — a view
  can always be rebuilt from the log alone.
- **Scheduler** (`AL.Scheduler`, `lib/AL/scheduler.ex`) — reacts to *raw*
  command-log writes directly (`:mnesia.subscribe({:table, …, :detailed})`),
  not to views, to drive `send_async`/`send_elixir`. A parallel consumer of
  the log, not something built on top of the projection — independent of
  views and caches entirely.
- **Caches** (`AL.ResolutionCache`, `lib/AL/dispatch/resolution_cache.ex`) —
  derived, disposable, per-branch memoization of expensive queries *over*
  views (`providers/3`, `oapply_clauses`, `native`, …), invalidated by the
  same writes that mutate the view they cache. Never a source of truth —
  correctness never depends on a cache entry existing, only speed does.
- **Extensible VM** (`AL.Native`, `AL.Native.Registry` — `lib/AL/native.ex`,
  `lib/AL/native/registry.ex` — and someday a jets mechanism) — the seam
  where the interpreter's dispatch can be handed capability the kernel has
  no way to derive itself. A view holds only a *symbolic reference* to what's
  expected (a durable `:native` fact — module/function/arity/style, a name,
  not code); *supplying* the implementation is this concern's own job, done
  via ordinary Elixir/OTP deployment (config, releases), never via anything
  the command log itself can execute. See
  [[al-natives-vs-jets-kernel-runtime]] for why a future jet, unlike a
  native, wouldn't need even the symbolic reference to be durable.

The interpreter proper (`AL` itself, `AL.Dispatch`, `AL.Interp.*`, `AL.Var`,
`AL.Choicepoint`) isn't a sixth concern of its own — it's what executes goals
*against* these five: reading views and caches, writing back only through
the command log's own `AL.Command`/`AL.Object` entry points (never touching
Mnesia directly outside `lib/AL/durable/`), and reaching into the extensible
VM specifically at `OApply` dispatch.

## Architecture (lib/AL)

- **`AL` (lib/AL.ex)** — the interpreter's core stepping engine:
  - `run do … end` → `AL.Lowering.ast_to_pattern` lowers surface syntax to
    `goal()` tuples → `eval/3` runs them in `:mnesia.transaction`. `run branch: b
    do … end` targets fork `b`; bare `run` uses `AL.Branch.head()`.
  - State = `%AL{active_choicepoint, choicepoint_stack, branch, tx_id, domino, …}`.
    `continue/1` drives goals, `backtrack/1` pops the stack. Success →
    `{:atomic, {output_vars, state}}`; failure `:mnesia.abort`s → `{:aborted, reason}`.
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
    `AL.Dispatch`. Inside an `interp/2` clause a goal's own fields arrive already
    resolved — `continue/1` substituted the goal against the store it hands down,
    so `var?(field)` means still unbound and `ground?(field)` means ground. Read
    them raw; `subst` is deep and idempotent, so adding one back is a no-op walk
    on a hot path. The guarantee is that entry path's, not the terms' — it stops
    at the clause boundary, so anything reached another way still needs
    resolving: a suspension key, a var off a stored link, `Findall`'s
    per-solution template, or a helper `AL.Dispatch` hands terms of its own.
  - `wake/2`, `unify/3`, `fresh_scope/0`, `cached_scan_clauses/2`,
    `put_bindings/3`, `fan_out/3`, `scan_clauses/5`, `standardize_apart/1`,
    `splice_goals/2` are `def` (not `defp`) specifically so `AL.Dispatch`,
    `AL.Interp.Store`, `AL.Interp.Relations`, and `AL.Interp.ControlFlow` can call
    back into them — all mutually recursive with `AL` (each calls `AL.interp/2`
    to run goals it splices; `interp`'s own clauses delegate out to them), which
    is fine across modules on the BEAM. `unify/3` is the one nearly every goal
    clause wants: `AL.unify(state, x, y)` pulls `store`/`branch` off `state`
    itself, so `branch` threading for `isa` (see `AL.Var`, below) stays
    invisible at ordinary call sites.
  - Object creation is **three-phase**: `construct` (ephemeral object, e.g.
    `%{class: self}`) → `allocate` (persist / give identity) → `init` (setup).
    `new` on `:class` chains all three (AL's take on ObjVLisp allocate/initialize).
- **`AL.Lowering` (lib/AL/lowering.ex)** — `ast_to_pattern/1`: a pure, stateless
  tree transform from the `run`/`defmethod` surface syntax to `AL.Goal` structs.
  No interpreter state, doesn't call `interp`/dispatch.
- **`AL.Dispatch` (lib/AL/dispatch/dispatch.ex)** — resolves a `send` into a
  concrete method application: candidate generation (generative/durable legs),
  the selector query, grounded application (`do_send`/`run_providers`), and DNU.
  See "How a `send` evaluates" below. Public entry points `dispatch/5`,
  `do_send_as/6`, `force_durable_candidates/4`, `run_providers/6`, `dnu/4` are
  what `AL`'s `interp/2` calls into; everything else is private. Every
  generative candidate's `isa` pinning is attached directly to the choicepoint
  `generative_candidate/5` builds, at construction — before its goals ever run,
  so it's live for the whole call including nested sends. `dispatch/5` also
  won't offer a candidate class that conflicts with `self`'s already-known isa
  set — any two distinct `super: :value` classes are mutually exclusive unless
  one is an ancestor of the other (`isa_conflict?/3`).
  `AL.Interp.Relations.GetClass`'s no-witness isa fast path calls the same
  predicate before registering a new isa.
- **`AL.Dispatch.MethodOrder` (lib/AL/dispatch/method_order.ex)** — the
  resolution-order topological sort (`method_scopes/2`, `super_chain/3`, Kahn's
  algorithm). Pure functions of a receiver/class and a branch, no choicepoint or
  bindings involved — the most standalone piece of the whole dispatch subsystem.
- **`AL.ResolutionCache` (lib/AL/dispatch/resolution_cache.ex)** — per-branch,
  flush-on-write Mnesia `ram_copies` (not ETS — a table has to outlive whichever
  transient process forked the branch) memoizing `providers/3`,
  `generative_descendants/1`, `durable_classes/1`, `answers_selector?` — pure
  functions of durable state, re-derived otherwise on every open dispatch.
  Naming follows `AL.Command`/`AL.Object`'s per-branch convention
  (`al_providers_cache@f`, …); created/dropped alongside a branch's other
  tables in `AL.Branch.setup/create_fork/discard`.
- **`AL.Continuation`/`AL.Choicepoint` (lib/AL/continuation.ex,
  lib/AL/choicepoint.ex)** — the two struct defs `AL` builds its state from;
  split out since they're pure data, no logic.
- **`AL.Interp.Store` (lib/AL/interp/store.ex)** — the object-mutation goals:
  `SetClass`/`SetSuper`/`SetMethod`/`SetOapply`/`SetSlots` and their five
  `Retract*` counterparts. Every one writes both the durable command log
  (`AL.Command`) and the in-memory projection (`AL.Object`) through one shared
  `write/3` helper. A goal whose `object` is already a live map (an ephemeral
  instance) is a no-op on all ten — ephemeral objects carry no command-log
  identity at all.
- **`AL.Interp.Relations` (lib/AL/interp/relations.ex)** — the relational *read*
  goals: `GetClass`/`GetSuper`/`GetMethod`/`GetOapply`/`GetSlots`. Each is a scan
  through `AL.Object` fanned out over `AL.fan_out/3`. `GetClass` is the one
  exception to "always scan": an unbound `object` with a ground `class` doesn't
  need a witness to succeed, so it registers an `isa` constraint instead of
  touching `AL.Object` at all. The reverse direction (both `object` and `class`
  unbound — querying self's class, not asserting it) has its own fast path too:
  if `object` already carries a known `isa` domain, `GetClass` answers from it
  directly instead of scanning.
- **`AL.Interp.ControlFlow` (lib/AL/interp/control_flow.ex)** — the
  choicepoint-stack control goals: `Cut`, `Implies`, `Or`, `Then`. Each is
  entirely about which alternatives stay on `state.choicepoint_stack`, never
  about producing a binding — see "Execution model" below.
- **`AL.Var` (lib/AL/var/var.ex)** — unification against one unified **store**: a
  var→entry map where an entry is either a bare bound term or an
  `AL.Var.ConstraintSet{dif, isa, bounds, domain}` struct for a still-open var
  carrying constraints — a binding is just the maximally-specific case of
  "what's known about this var," not a different kind of fact, and standard CLP
  theory doesn't distinguish them either. The struct (not a plain map) is what
  lets `deref/2` tell "still open, here's what's known" apart from "bound to a
  term that happens to be a plain map." `deref`, `subst`, `freshen`, `unify` all
  take this one store. `bind/4` runs an **occurs-check** (cons-aware for
  improper lists `[h | $tail]`) and checks the constraint set on a var *before*
  overwriting it with a bind (capture-then-check) — the one choke point a
  constraint is guaranteed to see every bind through, dispatch's own candidate
  generation included. `dif/2` and `isa` (`add_isa/3`) are its two original
  tenants, `bounds`/`domain` (see "Known gaps") joined later, all through the
  same slot. `isa_of/2` is the read side. Verifying `isa` needs a `branch` —
  `:number`/`:list`/`:map` are decidable from the term's own shape; a value
  class beyond those three is provable by matching one of its own
  *discriminating* clause heads (`AL.Dispatch.value_member?/3`); every other
  class is a relational fact costing one class-chain lookup. `AL.unify/3` (in
  `AL.ex`) is the state-aware convenience every other module calls;
  `AL.Var.unify/4` directly only when there's no `AL` state to pull
  `store`/`branch` from. Vars are atoms starting with `$` (`:"$x"`).
- **`AL.Command` (lib/AL/durable/command.ex)** — the event log. Each mutating goal
  writes a `{:command, t, tx_id, op}` row. `t` is a **global monotonic counter**
  shared across stores, so commands are globally ordered.
- **`AL.Object` (lib/AL/durable/object.ex)** — the projection: a RAM
  materialisation of the log (class/super/method/oapply as `:bag`, slots as
  `:set`). Rebuilt by replay (`hydrate_since`); `scan_*` query it.
- **`AL.Branch` (lib/AL/durable/branch.ex)** — forks. `fork(at \\ :tip, from \\
  head())` copies `from`'s log prefix into a new store + projection; writes
  diverge. Forks nest. `checkout` sets HEAD; `discard` tears a fork down.
  `AL.Command`/`AL.Object`/`AL.Branch` share `lib/AL/durable/` — together they
  *are* the append-only substrate; nothing else in the interpreter reaches into
  Mnesia directly.
- **`AL.Package` (lib/AL/package/package.ex)** — `defpackage` installs
  definitions as a durable receipt object; dependency-ordered, reversible
  `uninstall`. `bootstrap` is foundational (class/object/method machinery
  **and** the list protocol). Every installed package lives alongside it in
  `lib/AL/package/`.
- **`AL.Scheduler` (lib/AL/scheduler.ex)** — async. `send_async`/`send_elixir`
  are goals that only *write a command*; the scheduler reacts. **One scheduler
  per store** under a DynamicSupervisor, each subscribed to its own command
  table, so fork async stays on the fork. `Branch.fork`/`discard` start/stop it.
- **`AL.Trace`/`AL.Domino`/`AL.Source` (lib/AL/trace/)** — introspection. See
  "The domino tracing model" below for `AL.Domino` and `AL.Trace`'s live
  tracepoint printer; `AL.Source` decompiles a stored goal pattern back into
  readable AL surface syntax (used by the GlamorousToolkit method-coder view in
  `AL.Views`, `lib/AL/views.ex`).

## Execution model: choicepoints, marks, cut

The choicepoint stack mixes real `%Choicepoint{}` alternatives with two **boundary
sentinels** marking where a scope begins, so backtracking, `cut`, and `then` know
how far to reach:

- `{:mark, scope}` — pushed by `oapply`/`call` *below* a call's alternative
  clauses; `scope` is the call's freshener and equals the new frame's
  `scope_pointer`. `{:method_mark, scope}` — pushed the same way for a
  method-level (dispatch) candidate set, see below. `:implies_mark` — pushed by
  `implies`. All three are **inert during ordinary `backtrack`** (skipped, but
  logged as a domino Fail — see below).
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
just delegates to it from `interp/2`. `AL.begin_method_scope/5` wraps every
entry point (see "The domino tracing model" below) — mints a method-level
scope, retags the caller's `active_choicepoint.scope_pointer` to it (so every
choicepoint built downstream inherits it for free, being struct-copies of
`state.active_choicepoint`), and returns a wrapped `on_miss` that records a
domino Fail if nothing pans out.

**Two candidate families, not three — there is no `:ephemeral`/`:value`
strategy split.** `generative_candidate/5` always runs the same recipe
regardless of class: call the class's real `new` (fresh vars for its declared
ivars), unify `self` with whatever `new` produces, then `SendAsValue` the
actual requested method against `self`. Whether that leaves `self` genuinely
open (for value-leg-style clause matching, e.g. `:number`'s `factorial`,
`:letter_chain`'s literal clauses) or grounds it to a real constructed map
(e.g. `:interval`, `:square`) depends entirely on whether the class's own
`:init` discards the constructed scaffold or builds something real — `:value`'s
default `:init` (bootstrap.ex) is what makes the "stays open" case happen, not
a VM-level branch. A class opts into being a generative candidate at all just
by declaring `super: :value` (`generative_descendants/1` scans exactly that).
- **Durable** — real identity; must retrieve an existing object
  (`durable_candidates`), never fabricate one. A different resource from the
  generative leg, not a construction strategy.
- **Generative** (any `super: :value` class) — always constructs via the
  class's real `new`. `:list`'s `[]`/cons hypothesis is folded into this one
  mechanism (`import(:list, :value)`), no VM-level special case needed.

**Correct usage, not a VM constraint but a real convention:** a value class's
instances should be a self-describing map (a `:class` field, like
`:interval`/`:square`/`:card` — works as both a ground and an open receiver for
free) or left as a constrained-but-open var (`isa`, or `in_domain/2`), not
bound to a bare atom unless that atom is *also* durably classified. A bare
atom only gets symmetric dispatch through the durable class/super graph —
`next(x, :b)` finding `x = :a` via `:letter_chain`'s literal clauses works
(generative leg, no durable identity needed at all), but `next(:a, y)` fails
with `does_not_understand`, because ground dispatch on a plain atom only ever
consults the durable graph. Durably classifying it too creates a second,
independent proof of membership, so `findall` reports every fact twice, one
per leg — don't chase that fix, use a map or don't materialize a bare atom.

An **`isa` constraint** (`AL.Var.add_isa`) pins a var to a class the moment a
generative candidate's choicepoint is *constructed* — before any of its own
goals run, even if the matched clause leaves the var open. Sound because the
isa violation check only fires on a bind to a *concrete* term: a clause that
leaves `self` open never trips it during its own match, and a clause that
grounds `self` to one of the class's own literals is accepted by
`AL.Var.isa?/3` as membership evidence, so it doesn't self-violate the
constraint it's the proof of.

1. **Lowering (`AL.Lowering.ast_to_pattern`).** `send(recv, sel, args)` and implicit
   `sel(recv, …)` (any atom head with ≥1 arg) become `{:send, recv, sel, args}`.
   Direct VM ops never become sends: arithmetic (`+ - * / **`) and
   `@oapply_primitives` (`is`, `map_get`, `map_put`, `lookup`, `fresh_id`,
   `current_tx`) lower to `{:oapply, …}`; zero-arg `foo()` → `{:oapply, foo, []}`.
2. **Pre-substitution.** `continue` substitutes the goal against bindings before
   `interp` sees it, so "var receiver/selector" means *still unbound after deref*.
3. **`dispatch/5` picks a mode** (`:send` → `on_miss = dnu`; `:send_query` →
   `on_miss = backtrack`):
   - **var receiver** (not `:"$_"`) → candidates over two kinds, each pushed as
     a choicepoint (LIFO try order — generative candidates pushed *after* the
     durable placeholder, so tried first): `generative_descendants/1` scans
     every class with `super: :value`, `filter_by_selector` prunes to ones that
     answer the selector, `shape_conflict?` drops `:number`/`:list`/`:map`
     siblings once `self`'s known shape already picked one. Durable objects
     (deferred behind a placeholder choicepoint, filtered by
     `answers_selector?`) are tried last, only if backtracking gets that far.
     `install_method_choicepoints/3` appends `{:method_mark, method_scope}`
     below all of them.
   - **var selector** (not `:"$_"`) → query over the receiver's methods:
     `understood_method_names` walks `self` then its class/super chain (deduped); a
     choicepoint per name binds `sel`, then re-dispatches.
   - **both ground** → `do_send`. (Both var: receiver query grounds the object
     first, then the spliced `send_query` re-enters dispatch for the selector.)
4. **`do_send`** with `call_args = [self | args]`:
   - `providers/3`: ordered `{scope, id}` pairs from `method_scopes` crossed
     with `method_ids` per scope, cached per `(self's resolution key, selector,
     branch)`. `run_providers` tries them in order — **first clause match
     wins**, stashing the rest as a `call_next_method` cursor (no backtracking
     over candidates here — the query modes add that).
   - no candidates → `on_miss`.
   - candidate → `has_matching_clause?`: primitives `is/map_get/map_put/gensym/fresh_id`
     are allowlisted; else a freshened clause head must unify with `call_args`.
     No clause fits → `on_miss`.
   - match → `{:oapply, id, call_args}` (bidirectional; a method's other clauses
     become alternative choicepoints, tried in `seq` order — see "Tables" below).
5. **`on_miss`:** directed (`dnu`) re-sends as `does_not_understand(self, [sel,
   args])`, resolved like any send (default `:object` body is `:fail`); the `dnu`
   guard backtracks if `does_not_understand` itself isn't understood, so no loop.
   Query (`backtrack`) falls to the next candidate — **DNU never fires for a query.**

Edge cases: a query with no candidates fails, never DNUs; only fully-ground sends
DNU; `:"$_"` in receiver/selector is the match-anything wildcard, not a slot to
ground; of the two var-receiver candidate kinds, only durable objects require a
class row — generative candidates are offered regardless.

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
  it, so clause try-order is first-class data, stable across replay/fork.

Log + metadata (`AL.Command`, durable):
- `command {t, tx_id, command}` · `:ordered_set` — the append-only log. `t` is the
  global monotonic ordering key; `command` is the op. Authoritative; all else
  derives from it.
- `meta {key, value}` · `:set` — per-branch key/value (e.g. `:head` → current
  branch, kept in `:main`'s `meta`).

Lineage (`AL.Branch`, `:main` only):
- `branch {parent, child}` · `:bag` — fork lineage edges; HEAD is `meta[:head]`.

`:main` uses base table names; fork `f` uses `@f`-suffixed tables (`class@f`, …)
created with `record_name:` the base relation, so record tags and scan patterns
are identical across stores. Almost every `AL.Object`/`AL.Command` function
takes a trailing `branch \\ :main`.

## The domino tracing model (`AL.Domino`, `lib/AL/trace/`)

`state.domino.trace` is a structured call-tree log, always on and cheap
(bounded by call structure, not reduction count): 4 ports — Call/Exit/Redo/
Fail — at 2 levels, **method** (dispatch picking a provider, can itself
backtrack over candidate classes) wrapping **clause** (which clause of the
chosen method runs). Same Byrd-box framing classic Prolog tracers use, doubled
because AL has dispatch on top of clause selection where Prolog only has the
latter. Call/Exit carry a map of whatever was still open at that moment,
resolved against *that scope's own* store, not the run's final one — a var can
be merely narrowed by one call and only pinned down later by something
unrelated, so the final store would misattribute it; Redo/Fail stay bare.
`AL.begin_method_scope/5` opens a method box; `mark_exited/2` closes a clause
box natively (from `continue/1`'s continuation-pop) and propagates the exit
into its enclosing method box, since dispatch has no continuation of its own
to pop the way a clause call does. `state.domino.scopes` (one map, keyed by
scope: `%{parent, kind, open_vars, exited}`) is the bookkeeping that makes
this possible — set at Call, read at Exit/Redo/Fail, deleted at Fail.

Raw goals plus `:backtrack`/`:flounder` only join the same list when a run
opts in (`run vm_trace: true do ... end`) — interleaved in chronological
order, so a raw goal sits right next to the Call that's its context, no
cross-referencing needed. `AL.Trace.render/1` prints either shape
(reconstructs depth by walking Call/Exit as it goes), through the same
formatters the live `AL.trace(:selector)` printer uses (`AL.Trace.call/5`,
`exit/4`, `redo/4`, `fail/4` — all `(level, depth, receiver, method[, args])`,
`level` is `:method` or `:clause`). `iex -S mix debug` sets
`IEx.configure(inspect: [limit: :infinity, charlists: :as_lists])` for
reading a long trace by hand — invoking a custom Mix task this way skips the
normal app-start Mix does for you, so the task itself calls
`Mix.Task.run("app.start")` first (`lib/mix/tasks/debug.ex`). Examples in
`e_AL_trace.ex`.

`AL.Trace.dispatch/3` (live-printer only, fired from `AL.Dispatch.dispatch/5`'s
var-receiver branch) covers what the domino ports don't: *which candidate
legs* an unbound receiver had to try, printed before any of them run —
`value=[...]` (the selector-filtered `super: :value` class list) and
`durable=deferred`, deliberately not a count, since the durable leg's whole
point is not scanning until backtracking actually reaches it. Example:
`trace_shows_dispatch_legs` in `e_AL_trace.ex`.

`call_next_method` reports against the *original* send's method-level scope,
not a fresh one: `AL.Dispatch.run_providers/6` stashes its own position in the
resolution order as a cursor (`AL.cursor()`, 4th element is that method
scope), and `Goal.CallNextMethod`'s interp resumes from it, logging
`method_redo`/`method_fail` against that same box.

## Debugging a live session's failure state

A failed `run`/`next_solution` doesn't just hand back a curated summary — the
reason map (`message`/`reason`/`failed_on`/`trace`) also carries **`state`**:
the actual final `%AL{}`, whatever store/choicepoint_stack the last attempt
left behind before the stack exhausted. `reason.state` lets you inspect *what
was true when the last goal failed* — e.g.
`AL.Var.isa_of(reason.state.active_choicepoint.store, var)` for what was still
parked on a var, not just that some goal failed. Stripped back out (`nil`) on
the `heap:`-capped `eval` path (`AL.shed/1`), which exists specifically to
bound what crosses the process boundary. Example:
`failed_run_exposes_the_final_state` in `e_AL_failures.ex`.

A `unify(a, b)` failing because a `dif`/`isa` constraint rejected it looks
identical to an ordinary structural mismatch — `Goal.Unify`'s interp clause
calls `AL.Var.diagnose_unify_failure/5` on a `nil` result and, if it can
explain it, records `{:constraint_violated, violation}` into
`state.diagnostics`, so `reason.message` names the constraint directly.
Scoped to the direct "one side a still-open var carrying the constraint,
other side already concrete" shape; a var-vs-var mismatch or a failure from
some other goal calling `AL.unify/3` internally doesn't get this treatment,
returns `nil` (no diagnosis) rather than guessing. Example:
`unify_failure_names_the_violated_constraint` in `e_AL_failures.ex`.

## Adding a goal

1. `ast_to_pattern/1` clause (surface syntax → goal tuple) in lib/AL/lowering.ex.
2. Add it to the `goal()` typespec.
3. `interp/2` clause, in whichever module owns that goal's concern — a plain
   mutation goes in `AL.Interp.Store`, a plain scan in `AL.Interp.Relations`, a choicepoint-
   stack goal in `AL.Interp.ControlFlow`, a dispatch goal in `AL.Dispatch`; only add a
   clause directly to `AL` itself if the goal doesn't fit any of those (and
   add a one-line delegating clause to `AL`'s own `interp/2`, matching the
   existing ones, so `continue/1` still finds it). A mutating goal must
   **both** write the command (`AL.Command.*`) **and** apply to the
   projection (`AL.Object.*`); a read/query goal scans the projection and
   pushes choicepoints via `AL.fan_out/3`.
4. If it mutates, add a case to `AL.Object.hydrate_event/3` so replay/fork works.

No comments — repo-wide ban (al-practices' "Code style"), interpreter code included.

## Roadmap context

README promises **bitemporality** (valid-time, not just the log's transaction-time
`t`) and easy time-travel between branch points. Forks are the groundwork;
diff/merge and valid-time queries are unbuilt.

## Known gaps

- **Arithmetic bounds consistency for `< > <= >= eq`.** Both sides ground (via
  `interp_is/2`) is the original check; a side that derefs to a bare open var
  narrows an interval instead of failing (`AL.Var.add_compare/5`), living in
  the same `ConstraintSet` slot `dif`/`isa` do (`bounds :: {lo, hi}`) with its
  own `props` list of parked propagators — narrowing one var re-queues every
  other propagator on it, a worklist fixpoint (`AL.Var.run_fixpoint/3`), so
  `x < y, y < 5` tightens `x` transitively. A var whose bounds collapse to a
  single value binds outright through the existing `bind/4` (so `dif`/`isa`
  still gets checked). A compound expression with an open var still buried
  inside after `interp_is` (e.g. `n - 1` with `n` open) has no interval to
  narrow and hard-fails, same as `is/2` always has.

  `vm_label/1` (`Goal.Label`) is the companion CLP(FD) primitive: enumerates a
  still-open var's propagated `{lo, hi}` by *splicing a `between/4` send*
  (`:object`'s own recursive method), not `AL.fan_out/3` — `fan_out` builds
  every alternative eagerly, catastrophic for a wide domain (`between` only
  computes what backtracking actually visits). `factorial`/`fibonacci`
  (`bootstrap.ex`) collapse to one relational clause each on top of this: the
  inequalities are real invariants posted while `n` may be open, `vm_label(n)`
  is the single point concreteness gets forced either way. `fibonacci`'s bound
  (`n <= x + 1`) needs `x` wrapped in `implies`, relying on
  omitted-`:else`-is-vacuous-success (see al-practices' `implies` gotcha).
  Compound interval arithmetic (narrowing a var buried inside `+ - * /`) is
  still unbuilt. Examples in `e_AL_bounds.ex`; [[al-bounds-consistency]] for
  design history.

- **`in_domain/2`** — a real constraint (`ConstraintSet.domain :: MapSet.t() |
  nil`, alongside `dif`/`isa`/`bounds`), not a class with a `:domain` method.
  `AL.Var.add_domain/3` intersects across repeated posts; `find_violation/4`
  checks it at bind time like the other three. `vm_label`'s fallback chain
  gained a tier for it (between numeric bounds and the class-`:domain`-method
  fallback): just `member/2` over the narrowed set, no class/`SendAsValue`
  involved. Not eagerly cross-narrowed with `dif` — labeling enumerates via
  backtracking and each candidate still passes the normal bind-time check, so
  a `dif`'d value gets skipped there; sound, not maximally tight. Prefer
  non-atom domain values when the domain is conceptually "real things"
  (`:square`/`:card`-style) rather than plain symbols — a bare atom used only
  as an `in_domain` value quietly breaks the "bare atom ⇒ durable" invariant
  elsewhere in AL (`examine(:two, info)` returns nothing on an
  `in_domain`-only symbol). Examples in `e_AL_in_domain.ex`.

- **Ivar specs** — `defclass`'s `ivars:` can carry a per-ivar `domain:`/`type:`
  spec (`ivars: [suit: [domain: [:hearts, ...]]]`, mixable with bare-name
  ivars), and `:value`'s default `:init` wires checking + generation from it
  automatically. `domain:` posts `in_domain`; `type:` attaches `isa` so
  `vm_label`'s class-`:domain`-method fallback can generate a value. Zero VM
  changes — `ivars` was already opaque class metadata. New helper methods
  live on `:object`, not `:map` (a classed map dispatches via its own
  `:class` field, never through `:map`). `ivars: []` (every pre-existing
  value class) keeps the old default-`:init` behavior untouched. Decomposing
  a `{name, opts}` ivar entry uses `vm_functor`, not a bare-var fallback
  clause — see [[feedback-prolog-clause-selection-not-elixir]] for why that
  distinction matters. Explicitly deferred: numeric-range generation, durable
  (`:object`-super) classes. Demo in `lib/AL/package/blackjack.ex`'s `:card`.

- **Dispatch legs converged to one domain-constraint mechanism** —
  mechanically done, semantically still in progress. Every leg (generative,
  durable, `in_domain`) answers the same question — "self is unbound; what's
  its domain of possible values, and how do we get a concrete one when
  forced?" — differing only in how the domain is represented: a predicate
  domain (generative: class clause heads; `isa`: a class name) vs. an
  explicit set (durable: log-scanned ids; `in_domain`: a literal set). See
  `references/dispatch-domain-unification.md` for the full design history —
  what's merged, what's still semantically open (construction-time
  invariants like a `union`'s left/right disjointness), and a concrete
  double-proof bug this closed (a bare atom durably classified into a
  `super: :value` class whose own clause matches it — now guarded at both
  classification and definition time).

- **Durable candidate generation doesn't consult `isa`/`dif` before scanning.**
  `AL.Var.bind/4` being the one choke point means a wrong-class durable
  candidate is always *rejected* correctly, but `durable_candidates` still
  enumerates and unifies every selector-matching object first — an existing
  `isa` constraint could in principle narrow the scan itself. Not built; lower
  priority than correctness, which is already there.

- **Tuple literal parsing gap.** `AL.Lowering.ast_to_pattern` has no case for
  reconstructing a literal 3+-element tuple from Elixir's `{:{}, meta, list}`
  quoted form — writing `{:foo, 1, 2}` directly in AL surface syntax silently
  misparses as `send(:foo, :"{}", [1, 2])` instead of a tuple literal.
  (2-tuples are unaffected.) Workaround: build 3+-tuples via `vm_functor`
  instead of writing them as literals. Not fixed.

- **Atom-identity leak.** `fresh_id`/`gensym` mint atoms (`:"#N"`); the BEAM
  never garbage-collects atoms, and replay re-mints the same ones on top of
  whatever's already live. A long-lived node doing enough object creation
  eventually approaches the ~1M atom ceiling and dies. Fix is a non-atom
  identity scheme — invasive, needs its own design pass, not started.

- **Prior art, if extending constraints further**: CLOS generic-function
  dispatch has no analogue for "hypothesize a value for an unbound receiver"
  — it presupposes arguments already have concrete runtime classes, no
  unification/backtracking underneath. Prolog has no dispatch-by-type layer
  to hook into at all — clauses already *are* the generation policy; the
  problem AL solves here is self-inflicted by layering OO dispatch over
  logic search. Closest real precedent: **CLP(FD) `labeling(Strategy,
  Vars)`** (a pluggable policy for how an unbound finite-domain var gets
  concretized — `ff`/`min`/`max`/`bisect`) plus attributed-variable hooks
  (`attr_unify_hook/2`, `verify_attributes/3`, `freeze/2`).
