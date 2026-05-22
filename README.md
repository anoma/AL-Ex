# AL

**TODO: Add description**

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `al` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:al, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/al>.


TODO 

- Re-evaluate this list!

- Loads more docs

- concurrency

- constraint processing

- more bootstrapping for diff kinds of objects

- system wipes and rollbacks

## Known design issues

### `send` and `call_next_method`

Currently `send` is implemented as a bootstrap oapply behaviour. The `cut` after `oapply` in its body means that if a method body fails, backtracking reaches the `lookup` choicepoint and tries the next method in the super chain — giving a crude `call_next_method` via `fail`.

This has two problems:

1. **No scope delimiter.** `fail` in a method body backtracks to whatever is on the choicepoint stack, which may be an internal choice within the method body rather than the dispatch choicepoint. The dispatch scope is not properly delimited.

2. **Genuine failure is ambiguous.** A method that legitimately fails will silently fall through to the next method in the super chain rather than propagating failure to the caller. There is no way to distinguish "delegate to next method" from "this operation failed."

The fix requires `send` to be a native interp clause so it can push a delimiter marker onto the choicepoint stack around method body execution. A separate `call_next_method` primitive would then step over the delimiter to take the next `lookup` alternative, while `fail` would hit the delimiter and propagate outward. This also unblocks a proper call stack in the interpreter state for richer dispatch introspection.
