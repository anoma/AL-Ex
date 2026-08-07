---
name: al-practices
description: Conventions and day-to-day workflow for writing AL programs, packages, and examples against the existing language in this repo — defclass/DSL syntax gotchas, the example-driven testing workflow, code style, Mnesia store safety (forks vs mix al.reset), and how to read a debug trace. Use when writing or debugging AL surface-syntax code (defmethod/defclass/run blocks, packages, examples). For modifying AL's own interpreter/VM, use al-internals instead.
---

# AL practices

AL is an object-oriented Prolog running in this repo — see the `al-internals`
skill for how the interpreter itself works. This skill is about writing and
testing AL *programs* against it: surface syntax, testing workflow, and
day-to-day operational habits (Mnesia store safety, reading a trace).

## Testing workflow

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

## DSL gotchas

- **`do…end` bodies vs `[…]` goal lists.** A method/`run` body is a `do…end`
  block (goals newline- *or* comma-separated). `forall` takes its condition
  as a `[…]` list literal (comma-separated) but its body as a `do…end` block:
  `forall([cond_goals]) do body_goals end`. `findall(t, cond, r)`, `not`, and
  `call` still take **list literals** throughout — goals must be
  **comma-separated**, else a confusing `syntax error before: <goal>` (Elixir
  list syntax, not a parser bug).
- **`implies` uses a `cond`-style `->` block** (the only form):
  ```elixir
  implies do
    [cond_goals] -> then_goals
    [more_goals] -> body      # extra clauses read as `else if`, nesting in the else
    :else -> else_goals       # optional; omitting it splices an *empty* goal list
  end
  ```
  **Omitting `:else` is a vacuous success, not a failure** — `continue/1`
  treats a choicepoint with `goals == []` as a solved goal (nothing left to
  run), same as any other emptied-out goal list. If every `->` condition
  fails and there's no explicit `:else`, the whole `implies` still
  *succeeds*, leaving whatever vars the `then` branches would have bound
  untouched — surprising the first time, since "no branch matched" reads
  like it should fail. Write `:else -> fail` explicitly whenever "nothing
  matched" is meant to be a failure (bootstrap.ex's
  `factorial_search`/`fibonacci_search` are the reference example — this bit
  the first version of both, and `fibonacci`'s arithmetic-bounds derivation
  in al-internals' "Known gaps" deliberately *relies* on the vacuous-success
  behaviour once it was understood). Lowers to nested `{:implies, cond, then,
  else}`; branch bodies are `do`-block clauses, so it side-steps the comma
  gotcha. A `->` clause can't have an empty body — for an empty then-branch
  put the shared trailing goals inside each branch.
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
- **A map-shaped value class's `:init` must `unify` its output with a
  freshly literal-constructed map, not `set_slot`/`vm_set_slots` the input
  scaffold** (`:interval`'s own `:init`, `lib/AL/package/interval.ex`, is the
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
  `:list`'s own method, defined ~200 lines later in `bootstrap.ex`. Any
  `import(..., category)` call earlier than that point had the `member` send
  silently DNU-fail inside `findall`/`forall`, indistinguishable from `pairs`
  genuinely being empty. General lesson, applies to any package you write:
  a silent-failure send (DNU inside a `findall`/`forall`/`not`) reads
  identically to "no results," so a missing-provider bug at one of those
  call sites won't show up as an error — it shows up as an empty answer that
  looks legitimate until something expects a non-empty one.

## Code style

- Module docs are first-person ("I am …", "I provide …").
- **No comments, period.** Not "terse comments," not "only non-obvious why" — zero.
  Names and types carry meaning; a comment is never the fix for code that needs
  explaining. Keep docstrings terse when a moduledoc is genuinely required, but
  default to none. This applies repo-wide (interpreter code, tests/examples,
  bug fixes alike), not just AL surface syntax.

## Mnesia store safety

- Mnesia artifacts (`.mnesiastore/`, root `MnesiaCore.*`) are gitignored — never
  commit them.
- Mnesia store is a **shared, gitignored file** (`.mnesiastore/` by default,
  one directory per node) — `rm -rf`ing it is a genuinely destructive,
  process-wide operation, not a branch-scoped one, and will pull the store
  out from under *any other node currently running against it* (verified:
  two independent `mix run` processes sharing a store, each only touching
  its own fork, don't conflict at all — the wipe itself is the only thing
  that's actually unsafe). **Default to a throwaway fork**
  (`AL.Branch.fork()` … `checkout` … `discard`) instead of touching `:main`
  directly, whenever more than one person/process might be using the same
  checkout — see the README's "Working with multiple people" section for
  the concrete workflow, `mix al.reset` for the rare genuine-full-reset case.
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

## Reading a trace

- `run vm_trace: true do ... end` interleaves raw goals into a run's own
  `state.domino.trace`; `AL.Trace.render/1` prints it readably. `iex -S mix
  debug` configures `IEx.configure(inspect: [limit: :infinity, charlists:
  :as_lists])` so a long trace doesn't truncate mid-read. See al-internals'
  "The domino tracing model" for what the trace actually contains and why.
- On a *failed* run, `reason.state` carries the real final `%AL{}` — e.g.
  `AL.Var.isa_of(reason.state.active_choicepoint.store, var)` to see what was
  still parked on a var when the last goal failed, not just that it failed.
  Full mechanism (constraint-violation diagnosis, what's stripped on the
  `heap:`-capped path) in al-internals.
