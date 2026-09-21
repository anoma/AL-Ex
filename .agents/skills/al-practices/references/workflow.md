# AL program workflow

## Examples and tests

Examples in `lib/examples/e_AL_*.ex` are the surface-language specifications.
They are wired into `test/al_test.exs` through `ExExample.ExUnit`.

For a behavior change:

1. Add or adjust the smallest example that observes the relation.
2. Run the relevant example module with the isolated test helper.
3. Test the boundary cases exposed by the implementation: open variables,
   backtracking, constraints, DNU, inheritance, and persistence as applicable.
4. Run the complete suite when bootstrap or a shared protocol changes.

Use:

```console
.agents/skills/al-internals/scripts/test.sh test/al_test.exs:LINE
.agents/skills/al-internals/scripts/test.sh
```

The helper gives each run a fresh Mnesia directory. Never delete the checkout's
shared `.mnesiastore` to isolate tests.

## Bootstrap and live stores

Transaction programs are installed by name and version. Source edits do not
change an already-installed live branch. For current-source verification, use
the isolated test helper or a fresh fork/install path. Use `mix al.reset` only
for an intentional whole-store reset coordinated with other users of the
checkout.

Do not add image, replay, command-log, or old goal-shape compatibility for VM
changes unless the user explicitly requests it. A current change may require a
fresh test store; that is an operational fact, not permission to build a
migration layer.

## Tracing

Tracing uses composable flags:

```elixir
run trace: [:domino, :vm] do
  goals()
end
```

- No flags retain no execution history.
- `:domino` retains method/clause calls, successful choices, and constraint
  derivations.
- `:vm` adds raw VM goals to the same tagged event journal.
- `AL.Trace.derivation_tree(al)` accepts the completed state directly.
- `AL.Trace.render(Enum.reverse(al.trace.events))` prints the chronological
  event journal.
- `al |> AL.Trace.derivation_tree() |> AL.Trace.render_tree()` prints the
  successful call/answer derivation tree.

Constraint derivations belong to the call/answer path that produced them. A
split should appear under the method or later labeling call that owns the
choice, not be flattened into unrelated collection output.

## Async programs

Keep orchestration in AL. Host edges translate external events into AL
transactions and perform effects; they do not own application state machines.
Wait for causal completion events rather than polling or sleeping for guessed
durations. A local effect send completing does not prove the receiving AL
transaction committed.

Use `lib/examples/e_AL_peer.ex` as the reference shape for host-owned resources,
effect completion, and transaction-driven continuation.

## Style

Do not add comments. Use descriptive selectors, helper relations, clause shape,
and observable examples. Keep example modules topic-scoped and test behavior
rather than private storage representation.
