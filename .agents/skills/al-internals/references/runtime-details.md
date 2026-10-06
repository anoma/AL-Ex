+
# AL internals

AL is an **object-oriented Prolog**: a WAM-style abstract machine (`AL.JAM`) over an **append-only
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

- **Command log** (`AL.Command`, `lib/AL/command_log/command.ex`) — the
  append-only `{:command, t, tx_id, op}` Mnesia log. The one thing everything
  else either derives from or reacts to. Depends on nothing else here.
- **Views** (`AL.Object`, `AL.SourceStore`, `AL.Source` — `lib/AL/view/`) —
  materialised projections rebuilt by replaying the command log
  (`hydrate_since`/`hydrate_event`), plus `AL.Source`'s decompilation
  decompiler over that projection. Depend on the command log for what to
  project; nothing else depends on them *existing* — a view can always be
  rebuilt from the log alone.
- **Outbox** (`AL.Outbox`, `lib/AL/outbox.ex`) — receives a notification after
  a transaction commits, reads that transaction's `send_async`, `send_elixir`,
  and effect commands from the command log, and dispatches them outside the
  transaction. It is a parallel consumer of the log, independent of views and
  caches.
- **Caches** (`AL.ResolutionCache`, `lib/AL/cache/resolution_cache.ex`) —
  derived, disposable, per-branch memoization of expensive queries *over*
  views (`providers/3`, `oapply_clauses`, `native`, …), invalidated by the
  same writes that mutate the view they cache. Never a source of truth —
  correctness never depends on a cache entry existing, only speed does.
- **Extensible VM** (`AL.Native`, `AL.Native.Registry` — `lib/AL/native/`
  — and someday a jets mechanism) — the seam where the machine's
  dispatch can be handed capability the kernel has no way to derive itself.
  A view holds only a *symbolic reference* to what's expected (a durable
  `:native` fact — module/function/arity/style, a name, not code);
  *supplying* the implementation is this concern's own job, done via
  ordinary Elixir/OTP deployment (config, releases), never via anything the
  command log itself can execute. See [[al-natives-vs-jets-kernel-runtime]]
  for why a future jet, unlike a native, wouldn't need even the symbolic
  reference to be durable.

The engine proper (`AL` itself, `AL.JAM`, `AL.Dispatch`, `AL.Var`,
`AL.Choicepoint`) isn't a sixth concern of its own — it's what executes goals
*against* these five: reading views and caches, writing back only through
the command log's own `AL.Command`/`AL.Object` entry points (never touching
Mnesia directly outside `lib/AL/command_log/`, `lib/AL/view/`, and
`lib/AL/branch.ex`), and reaching into the extensible VM specifically at
`OApply` dispatch. `AL.Branch` (`lib/AL/branch.ex`) sits alongside all five
rather than inside any one of them — forking genuinely spans Command Log and
Views (copies a log prefix *and* provisions the projection/cache tables) and
also starts/stops the Outbox per branch.

## Architecture (lib/AL)

- **`AL` (lib/AL.ex)** — the transaction driver:
  - `run do ~AL"""…""" end` → `AL.Syntax` compiles the AL source to
    `AL.Goal` structs at compile time → `eval_captured` runs them in
    `:mnesia.transaction`. `run branch: b do … end` targets fork `b`; bare `run`
    uses `AL.Branch.head()`.
  - State = `%AL{active_choicepoint, choicepoint_stack, branch, tx_id, trace, …}`.
    `start_program/1` compiles the whole program into one machine query
    (`AL.JAM.query/1`, a `:progress` mutation after each top-level goal), so the
    active choicepoint's goals only ever hold `{:resume, frame}` entries, and
    frozen goals are parked as `{frame_id, code, slots}` in both the driver and
    the machine. `continue/1` resumes the machine,
    `apply_machine_result/2` turns what it yields back into driver state
    (installed choices, mutations, diagnostics, collection and `forall`
    continuations, cuts and commits), and `backtrack/1` pops the stack. Success →
    `{:atomic, {output_vars, state}}`; failure `:mnesia.abort`s → `{:aborted, reason}`.
  - There is no goal interpreter. Every goal runs as machine code (see `AL.JAM`).
  - Object creation is **three-phase**: `construct` (ephemeral object, e.g.
    `%{class: self}`) → `allocate` (persist / give identity) → `init` (setup).
    `new` on `:class` chains all three (AL's take on ObjVLisp allocate/initialize).
- **`AL.JAM` (lib/AL/jam.ex, lib/AL/jam/)** — the abstract machine that executes
  every goal. `AL.JAM.Compiler` compiles a method's clauses (head matchers from
  `AL.JAM.Head`, register-addressed instructions over `AL.JAM.Operand`s, clause
  indexing via `AL.ClauseIndex`) and caches them per branch; it also compiles
  runtime goal lists (`runtime/1`) for queries, relation rewrites and woken
  goals. `AL.JAM.step/12` runs instructions; a frame is
  `{id, code, pc, slots, returns, store, pending}` and alternatives live in the
  machine's own choice list. Instruction families delegate to
  `AL.JAM.Relation` (relational reads: class, super, method, clause, slot,
  command, branch facts, scheduling), `AL.JAM.Mutation` (durable writes and
  driver-state effects: output, source scopes, progress), `AL.JAM.Primitive`
  (term primitives), `AL.JAM.Constraint` (domains, `all_dif`, `floor_divide`,
  `either`), `AL.JAM.Label` (labelling), `AL.JAM.Format` (`vm_format`) and
  `AL.JAM.Trace` (ports). A goal the compiler cannot express is a compile
  error, never a handoff. The machine yields to the driver only for effects
  that need transaction state (`:mutation`), collection or `forall` results
  that need the driver, cuts and commits that reach driver choicepoints,
  diagnostics, failure, and a spent step budget (`:suspend`, resumed as-is).
- **`AL.Syntax` (lib/AL/syntax.ex)** — the only AL reader: a pure lexer,
  precedence parser from AL source to compound terms (`AL.Goal.Compound`),
  plus exact definition ranges for source retention. No machine state.
  `lib/AL/syntax.bnf` is generated by `mix al.bnf` from the `al_grammar` DCG in
  bootstrap, so it describes that grammar, which does not yet cover everything
  the reader accepts. The
  reader groups a source's `owner >> sel` clauses and emits `clear_method`
  before each group's first clause, so a source defines each method it
  mentions (Prolog reconsult); `clear_method` (bootstrap) retracts the
  method's clauses and keeps its id. The printer hides a `clear_method` that
  opens a group, so printing and reading stay exact inverses.
  `AL.Syntax.Printer` is its inverse (goals → AL source), used by every
  decompiled view.
- **`AL.Dispatch` (lib/AL/dispatch/dispatch.ex)** — the machine's dispatch
  queries: `target/3` (a ground receiver's first provider, or a native,
  or the understood selectors when the selector is unbound),
  `open_targets/4` (one plan per provider for an unbound receiver: a
  class provider constrains the receiver with `isa` and a selected-provider
  entry, a singleton provider binds it, a native provider applies directly),
  `next_provider/2` (the next provider from a `call_next_method` cursor),
  `miss_fails?/3` (whether a miss reports a diagnostic or sends
  `does_not_understand`), plus provider resolution, ivar specs and class
  membership (`isa_conflict?/3`, `value_member?/3`).
- **`AL.Dispatch.MethodOrder` (lib/AL/dispatch/method_order.ex)** — the
  resolution-order topological sort (`method_scopes/2`, `super_chain/3`, Kahn's
  algorithm). Pure functions of a receiver/class and a branch, no choicepoint or
  bindings involved — the most standalone piece of the whole dispatch subsystem.
- **`AL.ResolutionCache` (lib/AL/cache/resolution_cache.ex)** — per-branch,
  flush-on-write Mnesia `ram_copies` (not ETS — a table has to outlive whichever
  transient process forked the branch) memoizing `providers/3`,
  `generative_descendants/1`, `durable_classes/1`, `answers_selector?` — pure
  functions of durable state, re-derived otherwise on every open dispatch.
  Naming follows `AL.Command`/`AL.Object`'s per-branch convention
  (`al_providers_cache@f`, …); created/dropped alongside a branch's other
  tables in `AL.Branch.setup/create_fork/discard`.
- **`AL.Choicepoint` (lib/AL/choicepoint.ex)** — the driver's choicepoint
  struct; pure data.
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
- **`AL.Command` (lib/AL/command_log/command.ex)** — the event log. Each mutating
  goal writes a `{:command, t, tx_id, op}` row. `t` is a **global monotonic
  counter** shared across stores, so commands are globally ordered.
- **`AL.Object` (lib/AL/view/object.ex)** — the projection: a RAM
  materialisation of the log (class/super/method/oapply as `:bag`, slots as
  `:set`). Rebuilt by replay (`hydrate_since`); `scan_*` query it.
- **`AL.Branch` (lib/AL/branch.ex)** — forks. `fork(at \\ :tip, from \\
  head())` copies `from`'s log prefix into a new store + projection; writes
  diverge. Forks nest. `checkout` sets HEAD; `discard` tears a fork down.
  `AL.Command`/`AL.Object`/`AL.Branch` *are* the append-only substrate
  (`lib/AL/command_log/`, `lib/AL/view/`, `lib/AL/branch.ex` respectively) —
  nothing else in the engine reaches into Mnesia directly.
- **`AL.TransactionProgram` (lib/AL/transaction_program.ex)** — loads
  `priv/programs/<name>.al` (first form `defprogram name #{version => V,
  deps => [...]}.`), executes it, and creates a durable execution receipt;
  dependency-ordered, reversible `uninstall`. `bootstrap` is foundational
  (class/object/method machinery **and** the list protocol).
- **Package protocol (`priv/programs/package_system.al`)** —
  `:package` is the metaclass of package classes and `:package_build` supplies
  their instances' common build protocol. Package metadata and builds are
  durable branch state. `AL.Package.import/2` validates and atomically imports a
  portable manifest plus AL definition documents into an explicit branch;
  export and live package projection are not implemented yet.
- **`AL.Outbox` (lib/AL/outbox.ex)** — async. `send_async`/`send_elixir` and
  effects only write commands inside the transaction; after commit the outbox
  dispatches those commands. **One outbox per branch** runs under a
  DynamicSupervisor, so fork async stays on the fork. `Branch.fork`/`discard`
  start/stop it.
- **`AL.Trace`/`AL.Trace.Domino` (lib/AL/trace/)** — introspection. See "The
  tracing model" below for retained trace families, Domino call-tree evidence,
  and `AL.Trace`'s live tracepoint printer.
- **`AL.Source` (lib/AL/view/source.ex)** — decompiles a stored goal pattern
  back into readable AL surface syntax; a Views concern, not engine
  introspection, since it reads back out of the projection rather than
  tracing live execution. Used by the GlamorousToolkit method-coder view in
  `AL.GtBridge` (`lib/AL/gt_bridge.ex`, renamed from the unrelated
  `AL.Views`).

## Execution model: choicepoints, marks, cut

The machine keeps its own choice list of frames plus **boundary markers**:

- `{:jam_cut, ref}` — pushed below a call's alternatives when its clauses
  contain a cut (`:cut_scope`); the frame id carries the same ref, so `cut`
  drops the choice list to that marker. A cut in a `freeze` body opens its own
  scope, so it is local to the frozen goal.
- `:implies_mark` — pushed by `->`; the condition's `{:commit, then}` drops the
  choices down to and including it. `or` pushes the right branch as a plain
  alternative.
- `{:trace_alternative, scope, seq, entry}` and `{:trace_fail, tag, scope}` —
  only while tracing, so retries report `clause_chosen` and Fail ports.

When the machine yields, the driver installs the remaining choices as its own
choicepoints: frames become `%Choicepoint{goals: [{:resume, frame}]}`,
`{:jam_cut, _}` and `:implies_mark` stay as marks, and trace markers become
`{:mark, scope}`/`{:method_mark, scope}`. A cut whose marker is already on the
driver stack returns `{:cut, …}` and the driver drops its stack to it.

## How a `send` evaluates

A `send` compiles to a `{:send, site, object, method, args}` instruction (or
`{:send_local, …}` when its outputs are fresh locals the callee can write
directly). At runtime:

1. **Unbound receiver** → `AL.Dispatch.open_targets/4` builds one plan
   per provider of the selector, tried in order as alternatives.
2. **Unbound selector** → the receiver's understood selectors, one alternative
   per name, each re-sent as a query (a miss fails quietly).
3. **Both ground** → `target/3` picks the first provider (cached per
   receiver key and selector in the frame's targets), the callee's compiled
   clauses are selected by index and head match, and every matching clause is
   an alternative in `seq` order. A provider cursor rides in the frame for
   `call_next_method`.
4. **No provider** → a diagnostic when the receiver has the default
   `does_not_understand`, otherwise a re-send of `does_not_understand`.
   No matching clause → the same choice. A query send (`{:query, ref}` site)
   just fails.

`_` in the receiver or selector position finds no provider. The reader turns
each written `_` into its own fresh variable (`$_@N`), so `:"$_"` only appears
in Elixir-built patterns.

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

## The tracing model (`AL.Trace`, `lib/AL/trace/`)

Retained tracing is controlled by the composable `trace:` flag set and stored
under `state.trace`. No flags is the default and retains no execution history.
`:domino` records the structured call tree plus constraint evidence, and `:vm`
interleaves every VM goal. Constraint events are classified entries, not a
separate producer or flag. A future query explainer can add a new producer
without another top-level state field. The old `trace_mode:` values remain
compatibility shorthands: `:no_trace` is `[]`, `:derivation_trace` is
`[:domino]`, and `:full_trace` is `[:domino, :vm]`. Domino traces record 4 ports
— Call/Exit/Redo/Fail — at 2 levels, **method** (dispatch picking a provider, can itself
backtrack over candidate classes) wrapping **clause** (which clause of the
chosen method runs). Same Byrd-box framing classic Prolog tracers use, doubled
because AL has dispatch on top of clause selection where Prolog only has the
latter. Call/Exit carry a map of every variable still open at that moment,
including variables nested inside a receiver or argument, resolved against
*that scope's own* store, not the run's final one — a var can be merely narrowed
by one call and only pinned down later by something unrelated, so the final
store would misattribute it; Redo/Fail stay bare. Constraint events likewise
retain their immediate input and output descriptions. A collection answer owns
the final solution description; it is never substituted into its earlier
constraint nodes.
The machine emits every port through `AL.JAM.Trace` (the SWI-Prolog
approach: one engine with port hooks, and call-hiding shortcuts such as
`send_local` turned off while tracing). A traced send opens a method box
(`method_call/6`) and its callee a clause box (`clause_call/5`); a
`{:trace_exit, scope}` entry under the callee's return address fires Exit when
the callee returns and propagates it to the enclosing method box. Traced frame
ids carry their scope and clause number, `{:traced, scope, seq, id}`, so a
retry can report Redo and `clause_chosen`. `state.trace.runtime.scopes` (one map,
keyed by scope: `%{parent, kind, open_vars, exited}`) is the bookkeeping — set
at Call, read at Exit/Redo/Fail, deleted at Fail. During a machine run the
trace lives in the process dictionary and is handed back to the driver state
on every yield.

Every retained entry is an `%AL.Trace.Event{kind, payload}` tagged as either
`:domino` or `:vm`. Raw goals plus `:backtrack`/`:flounder` join
`state.trace.events` when a run enables `:vm` — interleaved in chronological
order, so a raw goal sits right next to the Call that's its context, no
cross-referencing needed. `state.trace.runtime` holds ephemeral scope,
tracepoint, and live-printer state; the trace's custom inspector omits it.
`AL.Trace.derivation_tree/1` accepts the completed `%AL{}` state, reads both
the retained journal and final variable store itself, and restores execution
order internally before constructing the successful derivation. Its materialized
tree alternates call nodes with successful answer nodes: a call owns its answers;
each answer owns its clause, derived bindings, and ordered nested method or
constraint steps. A method answer's derivation spans that method Call/Exit,
while a constraint node's derivation spans only that constraint's execution.
Redo rewinds later siblings and invalidates ancestor answers, so unsuccessful
attempts do not leak into the surviving tree.
`AL.Trace.render/1` prints a chronological event journal and reconstructs depth
by walking Call/Exit as it goes. `AL.Trace.render_tree/1` prints the successful
call/answer tree returned by `derivation_tree/1`. The event renderer uses the same
formatters the live `AL.trace(:selector)` printer uses (`AL.Trace.call/5`,
`exit/4`, `redo/4`, `fail/4` — all `(level, depth, receiver, method[, args])`,
`level` is `:method` or `:clause`). `iex -S mix debug` sets
`IEx.configure(inspect: [limit: :infinity, charlists: :as_lists])` for
reading a long trace by hand — invoking a custom Mix task this way skips the
normal app-start Mix does for you, so the task itself calls
`Mix.Task.run("app.start")` first (`lib/mix/tasks/debug.ex`). Examples in
`e_AL_trace.ex`.

`findall`, `forall`, and `not` run their conditions as isolated child searches
with a fresh trace (root scope 0), so bindings and choicepoints cannot leak. Their
finalized retained events
are prepended back into the outer reverse-chronological event stream, so tracing
still shows the work performed inside those meta-goals. Domino collection
markers retain each successful inner solution store before exhaustive search
resumes. `derivation_tree/1` merges those successful paths by their retained
call and answer identities. The collector is one call-like node with one answer;
the calls inside its condition own the actual alternatives. This keeps common
prefix constraints once and places downstream enumeration beneath the answer
whose constraints it consumes.

`AL.Trace.dispatch/3` (live-printer only, fired for an unbound receiver when
the selector is a tracepoint) prints the providers an open send will try, before
any of them run. Example: `trace_shows_dispatch_legs` in `e_AL_trace.ex`.

`call_next_method` opens a clause box for the next provider under the current
scope; it opens no method box of its own.

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

A `a = b` failing because a `dif`/`isa` constraint rejected it looks
identical to an ordinary structural mismatch — when a machine run fails on an
`=` instruction, the driver calls `AL.Var.diagnose_unify_failure/5` and, if it
can explain it, records `{:constraint_violated, violation}` into
`state.diagnostics`, so `reason.message` names the constraint directly.
Scoped to the direct "one side a still-open var carrying the constraint,
other side already concrete" shape; a var-vs-var mismatch or a failure from
some other goal calling `AL.unify/3` internally doesn't get this treatment,
returns `nil` (no diagnosis) rather than guessing. Example:
`unify_failure_names_the_violated_constraint` in `e_AL_failures.ex`.

## Adding a goal

1. A compile clause in `AL.Syntax` (call → goal struct), the matching print
   clause in `AL.Syntax.Printer`, and the name in `@special` if it is a reserved
   form.
2. Add it to the `goal()` typespec.
3. An `operation/2` clause in `AL.JAM.Compiler` and its execution in the
   module that owns the concern: a relational read in `AL.JAM.Relation`, a
   durable write or driver-state effect in `AL.JAM.Mutation`, a term primitive
   in `AL.JAM.Primitive`, a constraint in `AL.JAM.Constraint`. Add the matching
   `goal/2` clause there too (and an `instruction/2` clause in `AL.JAM` for a new
   instruction shape) so traces and failure messages can show it. A mutating
   goal must **both** write the command (`AL.Command.*`) **and** apply to the
   projection (`AL.Object.*`); a read returns `{:stores, stores}` for
   alternatives.
4. If it mutates, add a case to `AL.Object.hydrate_event/3` so replay/fork works.

No comments — repo-wide ban (al-practices' "Code style"), machine code included.

## Roadmap context

README promises **bitemporality** (valid-time, not just the log's transaction-time
`t`) and easy time-travel between branch points. Forks are the groundwork;
diff/merge and valid-time queries are unbuilt.

## Known gaps

- **Arithmetic bounds consistency for `< > <= >= =`.** Both sides ground (evaluated
  arithmetic) is the original check; a side that derefs to a bare open var
  narrows an interval instead of failing (`AL.Var.add_compare/5`), living in
  the same `ConstraintSet` slot `dif`/`isa` do (`bounds :: {lo, hi}`) with its
  own `props` list of parked propagators — narrowing one var re-queues every
  other propagator on it, a worklist fixpoint (`AL.Var.run_fixpoint/3`), so
  `x < y, y < 5` tightens `x` transitively. A var whose bounds collapse to a
  single value binds outright through the existing `bind/4` (so `dif`/`isa`
  still gets checked). A compound expression with an open var still buried
  inside after evaluation (e.g. `n - 1` with `n` open) has no interval to
  narrow and hard-fails.

  `vm_label/1` (`Goal.Label`) is the companion CLP(FD) primitive: enumerates a
  still-open var's propagated `{lo, hi}` by *splicing a `between/4` send*
  (`:object`'s own recursive method), not an eager list of alternatives, which
  would build every value up front, catastrophic for a wide domain (`between` only
  computes what backtracking actually visits). `factorial`/`fibonacci`
  (`priv/programs/bootstrap.al`) collapse to one relational clause each on top of this: the
  inequalities are real invariants posted while `n` may be open, `vm_label(n)`
  is the single point concreteness gets forced either way. `fibonacci`'s bound
  (`n <= x + 1`) needs `x` wrapped in `implies`, relying on
  omitted-`:else`-is-vacuous-success (see al-practices' `implies` gotcha).
  Compound interval arithmetic (narrowing a var buried inside `+ - * /`) is
  still unbuilt. Examples in `e_AL_bounds.ex`; [[al-bounds-consistency]] for
  design history.

- **`copy_term/3`** — `copy_term Term Copy Goals` gives `Term` with fresh,
  unconstrained variables and every constraint reachable from it as ordinary
  goals over the copy (`dif`, `class`, `isa`, bounds, `in_domain`, pending
  `super`/`slot`, `map_get` keys, `functor`, linear and other arithmetic
  relations, and suspended goals). Prolog's `copy_term/3`; the way to treat a
  constrained term as data, for example when writing it out.
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

- **Ivar specs** — a class's `ivars:` is a list of maps, each with a `name:`
  and optionally `domain:`/`type:`/`default:`/`storage:`
  (`ivars: [#{name => suit, domain => [hearts, ...]}]`). A bare name is rejected by
  `allocate_class` and by the definition document reader. `:value`'s default
  `:init` wires checking + generation from it automatically. `domain:` posts `in_domain`; `type:` attaches `isa` so
  `vm_label`'s class-`:domain`-method fallback can generate a value. Zero VM
  changes — `ivars` was already opaque class metadata. New helper methods
  live on `:object`, not `:map` (a classed map dispatches via its own
  `:class` field, never through `:map`). `ivars: []` (every pre-existing
  value class) keeps the old default-`:init` behavior untouched. Explicitly
  deferred:
  numeric-range generation, durable
  (`:object`-super) classes. Demo in `priv/packages/blackjack/definitions/card.class.al`.

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

- **No tuple surface syntax.** AL deliberately rejects Elixir tuple literals.
  Use lists, maps, or value objects for AL data. Internal VM encodings may still
  use tuples because they are not AL values written by a program.

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
