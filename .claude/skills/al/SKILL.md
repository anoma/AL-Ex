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

- **`AL` (lib/AL.ex)** — the interpreter, a choicepoint machine:
  - `run do … end` → `ast_to_pattern` lowers surface syntax to `goal()` tuples →
    `eval/3` runs them in `:mnesia.transaction`. `run branch: b do … end` targets
    fork `b`; bare `run` uses `AL.Branch.head()`.
  - State = `%AL{active_choicepoint, choicepoint_stack, branch, tx_id, …}`.
    `continue/1` drives goals, `backtrack/1` pops the stack. Success →
    `{:atomic, {output_vars, state}}`; failure `:mnesia.abort`s → `{:aborted, trace}`.
  - `interp/2` has one clause per goal. `oapply` expands a method head into its
    body **bidirectionally**: freshen the clause's vars by scope, unify head with
    call args into the *shared* binding map, run the body; a continuation resumes
    the caller with that same map — so head-var bindings made in the body are
    visible to the caller (no copy-back).
  - `send` resolves a method id up the class/super chain and applies it (see "How
    a `send` evaluates"). A **var in receiver or selector position makes the send a
    query** that backtracks over candidates; `does_not_understand` fires only for a
    fully-ground send.
  - Object creation is **three-phase**: `construct` (ephemeral object, e.g.
    `%{class: self}`) → `allocate` (persist / give identity) → `init` (setup).
    `new` on `:class` chains all three (AL's take on ObjVLisp allocate/initialize).
- **`AL.Var` (var.ex)** — unification. Bindings are a var→term map; `deref`,
  `subst`, `freshen`, `unify`. `bind/3` runs an **occurs-check** (`occurs?/3`,
  cons-aware for improper lists `[h | $tail]`) so cyclic terms can't form. Vars
  are atoms starting with `$` (`:"$x"`).
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

1. **Lowering (`ast_to_pattern`).** `send(recv, sel, args)` and implicit
   `sel(recv, …)` (any atom head with ≥1 arg) become `{:send, recv, sel, args}`.
   Direct VM ops never become sends: arithmetic (`+ - * / **`) and
   `@oapply_primitives` (`is`, `map_get`, `map_put`, `lookup`, `fresh_id`,
   `current_tx`) lower to `{:oapply, …}`; zero-arg `foo()` → `{:oapply, foo, []}`.
2. **Pre-substitution.** `continue` substitutes the goal against bindings before
   `interp` sees it, so "var receiver/selector" means *still unbound after deref*.
3. **`dispatch/5` picks a mode** (`:send` → `on_miss = dnu`; `:send_query` →
   `on_miss = backtrack`):
   - **var receiver** (not `:"$_"`) → query over objects: splice
     `[{:get_class, self, _}, {:send_query, …}]`; `get_class` enumerates every
     object with a class row (choicepoints), each grounded receiver re-dispatched
     as a query.
   - **var selector** (not `:"$_"`) → query over the receiver's methods:
     `understood_method_names` walks `self` then its class/super chain (deduped); a
     choicepoint per name binds `sel`, then re-dispatches. Arg shape decides which
     matches.
   - **both ground** → `do_send`. (Both var: receiver query grounds the object
     first, then the spliced `send_query` re-enters dispatch for the selector.)
4. **`do_send`** with `call_args = [self | args]`:
   - `resolve_method_id`: map receiver → `:class` key (default `:map`) chain; list
     → `:list`; atom → methods on it, else up its classes and their supers. **First
     match wins** — no backtracking over candidates here (the query modes add that).
   - no id → `on_miss`.
   - id → `has_matching_clause?`: primitives `is/map_get/map_put/gensym/fresh_id`
     are allowlisted (no stored clauses — e.g. `map`'s `:get` → `:map_get`); else a
     freshened clause head must unify with `call_args`. No clause fits → `on_miss`.
   - match → `{:oapply, id, call_args}` (bidirectional; a method's other clauses
     become alternative choicepoints).
5. **`on_miss`:** directed (`dnu`) re-sends as `does_not_understand(self, [sel,
   args])`, resolved like any send (default `:object` body is `:fail`); the `dnu`
   guard backtracks if `does_not_understand` itself isn't understood, so no loop.
   Query (`backtrack`) falls to the next candidate — **DNU never fires for a query.**

Edge cases: a query with no candidates fails, never DNUs; only fully-ground sends
DNU; `:"$_"` in receiver/selector is the match-anything wildcard, not a slot to
ground (falls to `do_send`, takes the first method — use a real var for a query);
the receiver query only sees objects with a class row.

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
function takes a trailing `branch \\ :main`.

## Adding a goal

1. `ast_to_pattern/1` clause (surface syntax → goal tuple) in lib/AL.ex.
2. Add it to the `goal()` typespec.
3. `interp/2` clause. Read/query goals scan the projection and push choicepoints;
   a mutating goal must **both** write the command (`AL.Command.*`) **and** apply
   to the projection (`AL.Object.*`).
4. If it mutates, add a case to `AL.Object.hydrate_event/3` so replay/fork works.

## Conventions

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
  It lowers (`build_implies/1`) to nested `{:implies, cond, then, else}`. Branch
  bodies are `do`-block clauses (newline-separated), so it side-steps the comma
  gotcha. A `->` clause can't have an empty body — for an empty then-branch put the
  shared trailing goals inside each branch.
- Module docs are first-person ("I am …", "I provide …").
- **No junk comments.** Don't restate code or narrate the obvious; names and types
  carry meaning. Comment only a non-obvious *why*. Keep docstrings terse.
- Mnesia artifacts (`.mnesiastore/`, root `MnesiaCore.*`) are gitignored — never
  commit them.
- **Don't `rm -rf .mnesiastore` to pick up a changed definition** — the log is
  authoritative append-only history. When a source change to a package/method
  isn't reflected (old definition already installed), test in a **throwaway fork**
  (`AL.Branch.fork` … `discard`) and patch at runtime. Caveat: `defmethod`
  *accretes* a clause rather than replacing, so to swap a buggy clause you must
  retract the old oapply or `uninstall` + reinstall — doing it in a fork you then
  discard keeps `:main` untouched.
- **Exception — a VM-level change to the goal encoding justifies a hard wipe.**
  Changing how a `goal()` is *represented* (tuple shape/arity, a new sentinel like
  `:next`, a reordered field) leaves goals in method bodies and the log in the
  **old shape**, which `interp/2` can no longer replay — the store can't rehydrate
  at all. Rather than carry permanent legacy `interp` clauses, `rm -rf
  .mnesiastore/` and let boot reinstall packages under the new encoding. (Tell:
  boot/replay crashes with a `function_clause` on an `interp({:set_oapply, …})`-style
  goal of the wrong arity.)

## Roadmap context

README promises **bitemporality** (valid-time, not just the log's transaction-time
`t`) and easy time-travel between branch points. Forks are the groundwork;
diff/merge and valid-time queries are unbuilt.

`method_scopes/2` (the materialised resolution order) is the substrate for a future
`call_next_method`: have resolution return its position in that list and let a
`call_next_method` goal re-resolve the selector from the next scope on.
