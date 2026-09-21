---
name: al-internals
description: Modify or debug AL's interpreter, goals, dispatch, durable command log and projections, branching, caches, source retention, or serialisation. Use for lib/AL.ex and lib/AL/{interp,dispatch,var,command_log,view,branch,cache,native,trace,serialisation}/, plus lib/AL/source_*.ex and lib/AL/serialisation.ex. For AL programs and package surface syntax, use al-practices.
---

# AL internals

AL is an object-oriented logic interpreter whose durable history is an
append-only Mnesia command log. Runtime objects and retained source are
projections of that history. Preserve that separation whenever changing the
VM or its tools.

When the implementation being changed is itself written in AL—especially
`bootstrap.ex` or `package_system.ex`—also read `al-practices` and its
relational-object programming reference. Do not replace a relational protocol
with Elixir-style branching merely because it lives in the bootstrap program.

## Start here

1. Read [references/architecture-map.md](references/architecture-map.md) when
   the task crosses subsystem boundaries or the relevant ownership is unclear.
2. Inspect the narrow public boundary before its implementation. Prefer
   `AL.Object`, `AL.SourceStore`, `AL.Serialisation.Snapshot`, or another structured
   API over raw table access from a new caller.
3. Identify the durable command and projection consequences before editing an
   interpreter path.
4. Run focused tests with `scripts/test.sh <test paths or line numbers>`. It
   gives the run an isolated, local Mnesia store. Run `scripts/test.sh` without
   arguments for the full suite.

For goal/choicepoint execution, dispatch legs, constraint propagation,
tracing, or the detailed known-gaps history, read
[references/runtime-details.md](references/runtime-details.md). For the
generative/durable/domain dispatch convergence specifically, read
[references/dispatch-domain-unification.md](references/dispatch-domain-unification.md).

## Invariants

- Keep the language/VM boundary explicit. Ordinary modeled behavior belongs in
  AL methods and public protocols; a `vm_*` operation belongs at the bottom of
  that protocol, in exact structural reconciliation, or in a deliberate
  primitive test.
- Preserve relational modes. Interpreter fast paths may optimize a relation but
  must not silently turn an open or bidirectional call into a grounded-only one.
- AL surface terms do not include Elixir tuples. Internal goal encodings,
  Mnesia rows, and private Elixir return values may use tuples, but they must not
  leak into the surface language.

- `AL.Command` is durable authority. `AL.Object`, `AL.SourceStore`, caches, and
  serialised files are derived and must remain rebuildable.
- A durable mutation passes through an `AL.Goal`, is interpreted inside the
  current AL transaction, writes the command log, and updates its projection
  with the command's transaction time. Do not make a durable side write that
  bypasses this path.
- Keep branch identity explicit through reads, writes, cache keys, source
  lookup, and tests. Never assume the head branch inside a helper already given
  a branch.
- Method binding identity, selector, and ordered clauses are separate facts.
  Preserve method IDs during source edits; replacing clauses must not silently
  replace the method object.
- Source retention is anchored to command transaction times. Retained text and
  source spans must agree; use a decompiled representation only when retained
  text is unavailable or invalid.
- Multiple inheritance is supported. Dispatch order and superclass sequence
  are semantic data, not a set.
- Caches may improve speed but never establish correctness. Every mutation that
  changes a cached query's answer must invalidate the corresponding cache.
- Failed transactions are observable transaction objects too. Changes to
  transaction recording must account for both committed and failed runs.
- Mnesia calls that require transaction context must stay inside a transaction.
  Prefer a public wrapper plus a clearly named `*_in_transaction` function when
  both external and composing callers need the operation.
- A write path inside a transaction must read by key. Mnesia's transaction
  store is indexed by `{table, key}`, so `read/2,3` reaches one key, while
  `select` and `match_object` merge by scanning every operation the transaction
  has already recorded for that table. Reading by pattern in a write path is
  therefore quadratic in the transaction's own size, which is invisible in a
  small transaction and catastrophic in a large one. Reach for the pattern scan
  only when the key is genuinely non-ground, and filter in Elixir otherwise.
- Only the process that owns a projection may rebuild it. A joining node shares
  the owner's `ram_copies` tables, so replaying the log there duplicates live
  rows rather than reconstructing them.

## Serialisation boundary

- `AL.Serialisation.Document` owns the Tonel-like file codec. Headers are generated
  metadata; method bodies contain retained or marked decompiled source.
- `AL.Serialisation.Layout` owns branch and definition paths. Keep its path
  segments injective and unable to escape the configured root.
- `AL.Serialisation.Snapshot` captures all live facts needed to render and diff
  definitions. Add facts here when planning otherwise needs another Mnesia
  read.
- `AL.Serialisation.Sync.plan/3` is pure. It accepts a snapshot plus edited/deleted
  owners and returns a deterministic transaction plan.
- `AL.Serialisation` owns filesystem reconciliation, watching, batching, source
  capture, and evaluation. Keep table interpretation and semantic diffing out
  of it.
- Transaction files remain an append-only projection of retained transaction
  source. Definition documents are editable projections that produce new
  transactions.

## Change discipline

- Add or change a goal: update the struct/type, lowering, interpreter handler,
  stored representation if applicable, command log operation, projection, and
  replay path as one semantic change.
- Change the current runtime coherently. Do not add image, replay, command-log,
  stored-state, or old goal-shape compatibility unless the user explicitly asks
  for it. Use a fresh isolated store for verification when old data cannot be
  read by the new runtime.
- Change dispatch: test bound and unbound receivers, durable and generative
  legs, inheritance ordering, backtracking, cut, DNU, and cache invalidation as
  applicable.
- Change source retention: test exact slicing, nested shorthand, failed
  transactions, missing spans, and decompiled fallback.
- Change source synchronization: test the pure plan first, then watcher and
  restart integration separately.
- Fix a bug at the smallest observable boundary. Avoid tests that merely mirror
  a private implementation.

## Store safety

Use a branch fork for ordinary work. Never remove `.mnesiastore` to obtain test
isolation. Use `scripts/test.sh` or set both `AL_MNESIA_DISTRIBUTED=false` and a
fresh `AL_MNESIA_DIR`. Use `mix al.reset` only for an intentional full-store
reset after coordinating with anyone using the checkout.

## Live MCP workflow

When the `almcp` tools are available, they operate inside the running AL owner
node and therefore see the same store and branches as GT and IEx.

- Call `listBranches` before branch-sensitive work and pass the intended branch
  explicitly when mutating it.
- Use `evaluate` for read-only Elixir inspection and runtime administration. It
  imports `AL` and aliases the common AL modules for each call.
- Use `evaluateSource` for AL definitions and mutations. It calls
  `AL.eval_source/3`, retains exactly the submitted AL text, and returns the
  committed or failed transaction object.
- Treat a generic `evaluate` call as live code execution. Do not use raw Mnesia
  writes or projection writes to bypass AL's transaction path.
