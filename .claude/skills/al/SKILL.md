---
name: al
description: How the AL runtime works and how to extend it — use when working in this repo (the Elixir object-oriented Prolog / WAM interpreter over an append-only Mnesia command log). Covers the goal/choicepoint VM, event-sourced object stores, forks/branches, packages, async scheduling, and the conventions for adding goals, packages, and examples.
---

# AL

AL is an **object-oriented Prolog**: a WAM-style interpreter over an **append-only
command log** in Mnesia. Live relational objects, bidirectional execution,
ACID transactions, durable + replayable state, Git-like branching.

## Mental model (design philosophy)

- **Commitment machine.** The runtime is a *stack of transactional state machines*
  layered ephemeral → durable. The durable base is the append-only on-disk
  command log ("your personal, authoritative history"); more ephemeral layers
  (the object projection) are derived from it and a commit cascades upward.
  Changes are atomic — all succeed or all fail (this is why everything runs in a
  Mnesia transaction). Distribution is meant to come from systems *interacting*,
  not sharing a log — each node has total authority over its own history.
- **Objects are relational, not primary.** An object doesn't exist independently;
  it *emerges* from relations (`class(a, …)`, `super(…)`, `slot value …`). The
  object tables are literally a materialised view of the command log — which is
  what makes replay, forks, and (planned) bitemporal queries fall out for free.
- **Inheritance is just a relation** (`super`), so the class graph and its search
  order are ordinary data, not a fixed matrix — multiple inheritance is free.
- **Backtracking is a feature, not just control flow.** WAM semantics give full
  backtracking + bidirectional execution, so you can `send` to an *anonymous /
  underspecified* receiver and let the runtime search for the object(s) that
  match (a var in receiver position acts as a query over the store).

## Architecture (lib/AL)

- **`AL` (lib/AL.ex)** — the interpreter. A choicepoint machine:
  - `run do … end` macro → `ast_to_pattern` lowers surface syntax to `goal()`
    tuples → `eval/3` runs them inside `:mnesia.transaction`. `run branch: b do … end`
    runs against branch `b` (a fork); bare `run` uses `AL.Branch.head()`.
  - State = `%AL{active_choicepoint, choicepoint_stack, branch, tx_id, …}`.
    `continue/1` drives goals; `backtrack/1` pops the stack. Success returns
    `{:atomic, {output_vars, state}}`; failure `:mnesia.abort`s → `{:aborted, trace}`.
  - `interp/2` has one clause per goal. `oapply` expands a method head into its
    body **bidirectionally**: it freshens the clause's vars by scope, unifies the
    head with the call args into the *shared* binding map, runs the body, and a
    continuation resumes the caller with that same map — so anything the body
    binds to a head var is visible to the caller's linked vars (no copy-back step).
  - `send` resolves a method id up the class/super chain and applies it (see
    "How a `send` evaluates" below). A **var in the receiver or selector
    position turns the send into a query** that backtracks over candidate
    objects / methods; `does_not_understand` fires only for a fully ground
    (directed) send.
  - Object creation is **three-phase**: `construct` (make an ephemeral object,
    e.g. `%{class: self}`) → `allocate` (persist it / give it identity) →
    `init` (setup logic). `new` on `:class` chains all three; this is AL's take on
    ObjVLisp's allocate/initialize.
- **`AL.Var` (var.ex)** — unification. Bindings are a var→term map; `deref`,
  `subst`, `freshen`, `unify`. `extend` binds via `bind/3`, which runs an
  **occurs-check** (`occurs?/3`, cons-aware for improper lists `[h | $tail]`) so
  cyclic terms can't be created. Vars are atoms starting with `$` (`:"$x"`).
- **`AL.Command` (command.ex)** — the event log. Each mutating goal writes a
  `{:command, t, tx_id, op}` row. `t` is a **global monotonic counter** shared
  across all stores (so commands are globally ordered — this is what makes
  cross-branch diff/merge by `t` well-defined).
- **`AL.Object` (object.ex)** — the projection: a RAM materialisation of the log
  (relations: class/super/method/oapply as `:bag`, slots as `:set`). Rebuilt by
  replay (`hydrate_since`). `scan_*` query it.
- **`AL.Branch` (branch.ex)** — forks. `fork(at \\ :tip, from \\ head())` copies
  `from`'s log prefix into a new store + projection; writes then diverge. Forks
  can be forked. `checkout` sets HEAD; `discard` tears a fork down.
- **`AL.Package` (package.ex)** — `defpackage` installs definitions as a durable
  receipt object; dependency-ordered, with reversible `uninstall`. Installed at
  boot from `config :al, :packages`. `bootstrap` is foundational (it defines
  class/object/method machinery **and the list protocol**: hd, tl, concat,
  reverse, map, fold, flatten, same_length).
- **`AL.Scheduler` (scheduler.ex)** — async. `send_async`/`send_elixir` are VM
  goals that only *write a command*; the scheduler reacts. **One scheduler per
  store** (`:main` + each fork) under a DynamicSupervisor: each subscribes to its
  own command table and dispatches against its own store, so fork async stays on
  the fork. `Branch.fork`/`discard` start/stop a fork's scheduler.

## Execution model: choicepoints, marks, cut

The choicepoint stack mixes real `%Choicepoint{}` alternatives with two **boundary
sentinels** that mark where a scope begins, so backtracking, `cut`, and `then`
know how far to reach:

- `{:mark, scope}` — pushed by `oapply`/`call` *below* a call's alternative
  clauses; `scope` is the call's freshener, and the new frame's `scope_pointer`
  equals it. `:implies_mark` — pushed by `implies`. Both are **inert during
  ordinary `backtrack`** (skipped, `{:mark, f}` also emits a trace-fail).
- **`cut`** drops the stack down to (not including) the `{:mark, f}` whose `f`
  matches the active frame's `scope_pointer` — committing every choice made inside
  the current method/call scope.
- **`implies(cond, then, else)`** runs `cond ++ [{:then, then}]` and pushes
  `[else_choicepoint, :implies_mark]`. If `cond` fails, backtracking reaches
  `else_choicepoint`. If `cond` succeeds, the `{:then, _}` goal drops the stack
  down to and including `:implies_mark` — discarding both `cond`'s remaining
  alternatives and the else branch (a soft cut / commit to `cond`'s first solution).
- **`or`** just pushes the right branch as a normal choicepoint (no mark).
- `scope_pointer` is carried in continuations, so returning from a method restores
  the caller's scope for the next `cut`.

## How a `send` evaluates

1. **Lowering (`ast_to_pattern`).** `send(recv, sel, args)` and the implicit
   `sel(recv, …)` (any atom head with ≥1 arg) both become `{:send, recv, sel,
   args}`. Names that are direct VM ops never become sends: arithmetic
   (`+ - * / **`) and `@oapply_primitives` (`is`, `map_get`, `map_put`,
   `lookup`, `fresh_id`, `current_tx`) lower straight to `{:oapply, …}`; a
   zero-arg `foo()` → `{:oapply, foo, []}`.
2. **Pre-substitution.** `continue` substitutes the goal against the bindings
   before `interp` sees it, so "var receiver/selector" means *still unbound
   after deref*.
3. **`dispatch/5` picks a mode** (`:send` passes `on_miss = dnu`, `:send_query`
   passes `on_miss = backtrack`):
   - **var receiver** (not `:"$_"`) → query over objects: splice
     `[{:get_class, self, _}, {:send_query, …}]`; `get_class` enumerates every
     object with a class row, binding `self` with choicepoints, and each
     grounded receiver is re-dispatched as a query.
   - **var selector** (not `:"$_"`) → query over the receiver's methods:
     `understood_method_names` walks `self` then its class/super chain
     (deduped); a choicepoint per name binds `sel`, then re-dispatches as a
     query. The arg shape decides which match.
   - **both ground** → `do_send`. (Both var: receiver query fires first, grounds
     the object, and the spliced `send_query` re-enters dispatch for the selector.)
4. **`do_send`** with `call_args = [self | args]`:
   - `resolve_method_id`: map receiver → `:class` key (default `:map`) chain;
     list → `:list`; atom → methods defined directly on it, else up its classes
     and their supers. **First match wins** — no backtracking over candidates
     here (that's what the query modes add).
   - no id → `on_miss`.
   - id → `has_matching_clause?`: the primitive selectors
     `is/map_get/map_put/gensym/fresh_id` are allowlisted (no stored clauses —
     e.g. `map`'s `:get` → `:map_get`); else a freshened clause head must unify
     with `call_args`. No clause fits the arg shape → `on_miss`.
   - match → `{:oapply, id, call_args}` (bidirectional expansion; a method's
     other clauses become alternative choicepoints — see the execution model).
5. **`on_miss`:** directed (`dnu`) re-sends as `does_not_understand(self, [sel,
   args])`, resolved like any send (default `:object` body is `:fail`); the
   `dnu` guard backtracks if `does_not_understand` itself isn't understood, so no
   loop. Query (`backtrack`) just falls to the next candidate — **DNU never fires
   for a query send.**

Edge cases: a query with no candidates fails (backtracks), never DNUs; only
fully-ground sends can DNU; `:"$_"` in receiver/selector position is the
match-anything wildcard, not a slot to ground (it falls to `do_send`, scans as a
wildcard, takes the first method — use a real var for a query); the receiver
query only sees objects that have a class row.

## Stores

`:main` uses base table names; a fork `f` uses `@f`-suffixed tables
(`class@f`, `command@f`, …) created with `record_name:` the base relation, so
record tags and scan patterns are identical across stores. Almost every
`AL.Object`/`AL.Command` function takes a trailing `branch \\ :main`.

## Adding a goal

1. `ast_to_pattern/1` clause (surface syntax → goal tuple) in lib/AL.ex.
2. Add it to the `goal()` typespec.
3. `interp/2` clause. Read/query goals scan the projection and push
   choicepoints; a mutating goal must **both** write the command
   (`AL.Command.*`) **and** apply to the projection (`AL.Object.*`).
4. If it mutates, add a case to `AL.Object.hydrate_event/3` so replay/fork works.

## Conventions

- **Examples are the tests.** They live in `lib/examples/e_AL_*.ex` as ExExample
  `example` blocks and are wired into `test/al_test.exs` via
  `use ExExample.ExUnit, for: Examples.X`. Run with `mix test`. Examples are
  memoised nodes — one `example` can call another to reuse its result.
- **Every bug fix ships with a test.** When you discover a bug, before/with the
  fix write the *simplest* `example` that exercises the correct behaviour — one
  that fails on the old code and passes on the new. This is the primary way AL
  pins down its subtle semantics (unification, cut/marks, bidirectionality), so a
  fix without a regression example is incomplete.
- Keep example files **topic-scoped**: `e_AL_arithmetic.ex` (`is/2`),
  `e_AL_lists.ex`, `e_AL_tasks.ex` (async), `e_AL_branch.ex` (forks), etc. When a
  feature stops being about `Examples.AL`'s general surface, give it its own file
  and wire a `…Test` module in `al_test.exs`.
- Test capabilities, not sugar: e.g. async tests build their receiver from
  bootstrap primitives (`defmethod`) rather than a convenience package.
- **DSL gotcha — `do…end` bodies vs `[…]` goal lists.** A method/`run` body is a
  `do…end` block, so goals are newline- *or* comma-separated. But the branches of
  `forall(cond, body)`, `findall(t, cond, r)`, `not`, and `call` are **list
  literals** — their goals must be **comma-separated**. Writing them
  newline-separated like a block gives a confusing `syntax error before: <goal>`.
  (Not a parser bug — just Elixir list syntax.)
- **`implies` uses a `cond`-style `->` block** (the only form):
  ```elixir
  implies do
    [cond_goals] -> then_goals
    [more_goals] -> body      # extra clauses read as `else if`, nesting in the else
    :else -> else_goals       # optional; omitting it means an empty (failing) else
  end
  ```
  It lowers (via `build_implies/1` in lib/AL.ex) to nested `{:implies, cond, then,
  else}` goals. Branch bodies are `do`-block clauses (newline-separated goals), so
  unlike `forall`/`findall`/`not` it side-steps the comma gotcha above. A `->`
  clause can't have an empty body, so for an empty then-branch put the shared
  trailing goals inside each branch instead.
- Module docs are written first-person ("I am …", "I provide …").
- **No junk comments.** Do not add comments that restate the code, narrate the
  obvious, or explain a one-liner. Names and types carry the meaning; comment only
  a non-obvious *why*. Keep docstrings terse — a single line is usually enough.
- Mnesia DB artifacts (`.mnesiastore/`, root `MnesiaCore.*`) are gitignored —
  never commit them. The store persists across runs, so stale objects can linger
  after a package is removed (retract with `AL.Package.uninstall/1` or wipe
  `.mnesiastore/`).
- **Don't `rm -rf .mnesiastore` to pick up a changed definition.** The on-disk
  command log is meant to be authoritative, append-only history — wiping it
  throws that away. When a source-level change to a package/method isn't
  reflected (because the old definition is already installed in the durable
  log), test in a **throwaway fork** (`AL.Branch.fork` … `discard`) and patch at
  runtime there. Caveat: `defmethod` *accretes* a clause rather than replacing,
  so to truly swap a buggy method clause you must retract the old oapply/clause
  or `uninstall` + reinstall the package — doing that inside a fork you then
  discard keeps `:main` untouched.

## Roadmap context

README promises **bitemporality** (valid-time, not just the log's transaction-time
`t`) and easy time-travel between branch points. Forks are the groundwork;
diff/merge and valid-time queries are unbuilt.

`method_scopes/2` (the materialised resolution order) is the substrate for a
future `call_next_method`: have resolution return its position in that list and
let a `call_next_method` goal re-resolve the selector from the next scope on.
