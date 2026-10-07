# AL

AL is a bitemporal operating system which performs constraint resolution over a metaobject protocol. 

## Features

- **Relational Objects** Objects support multiple inheritance and constraint-resolving method dispatch. Partially known objects are refined through ordinary message sends.
- **CLP(FD)** Bounds consistency, `dif`, and global constraints like `all_dif` (Régin's algorithm). Pluggable constraint systems.
- **Inside-Out Architecture** Every change is logged to disk. Restart and continue where you left off.
- **ACID Effects** OS-level operations are performed 'at the edge' of ACID transactions and their results cascade into subsequent transactions.
- **Git-like branching** Fork system state from historical states, work in isolation, discard or retain work.
- **Bitemporal Querying** Query independently over transaction time and valid time.
- **Internal package management** GUIX-inspired package resolution + general build solving.

## Inspiration

We model AL as the ideal substrate for constructing 'commitment machines'. By this, we mean it is structured as a tower of transactional state machines with distinct semantic layers, separating exploratory computation from durable commitments. The command log forms the locally authoritative, durable base of a single node. The relational-object system permits the machine to dynamically grow new abstract layers, and the machine's roots deepen through distributed interactions between nodes.

Modern long-lived, data-intensive applications scatter wonderful ideas across many unrelated systems. AL provides an operating environment where all of these concepts are unified. The goal of the system is to provide the largest open-polymorphic surface possible in a virtualised operating system, and, as a north star, to be the personal computing environment of the future.

AL combines inspiration from:

- XTDB

- GlamorousToolkit/Pharo

- Git

- PROLOG/Logtalk

- LISP

- BEAM

- Urbit

- Gemstone/S

This runtime is the prototypical version of AL, written in Elixir. The irony of the first Erlang interpreter having been written in PROLOG is not lost on us.

## Quickstart

Install from terminal using `iex -S mix` or as a mix dependency.

`lib/examples` contains examples.
`lib/AL` contains the runtime code.
`lib/AL/syntax.bnf` is the grammar of AL source.
`editors/al-mode.el` is an Emacs major mode for `.al` files.
`priv/programs` contains the transaction programs, such as `bootstrap.al`, that set up an image.
`priv/packages` contains the packages that will be installed upon image setup.

### Source and exports

Packages are the authored source boundary. Runtime changes and retained
transaction source remain in the durable store; AL does not automatically mirror
them into `src/al` or import filesystem edits into live definitions.

Export through packages when needed:

```elixir
AL.Package.export(:users, to: "/tmp/users-package")
AL.Package.export(:my_package, definitions: [:my_class], to: "/tmp/my-package")
```

Package loading and activation remain explicit. Definition documents, live
snapshots, and change planning are shared through `AL.Definition`.

## Livebooks

The fastest way to try AL is [`livebooks/intro.livemd`](livebooks/intro.livemd) and the notebooks it links to. `mix escript.install hex livebook` followed by `livebook server` gets you Livebook itself if you don't already have it.

## Working with multiple sessions at once

AL persists to a local, gitignored Mnesia store (`.mnesiastore/` by default) that every `iex -S mix`/`mix run`/`mix test` invocation in a checkout shares unless told otherwise.

You can utilise forks to have multiple streams work on the same node without conflict. 

```elixir
fork = AL.Branch.fork() <- fork from HEAD
AL.Branch.checkout(fork) <- change HEAD to fork
AL.Branch.discard(fork) <- discard the fork
```

Further isolation should be accomplished by configuration of the Mnesiastore dir.

## Tracing

Retain executed JAM instructions for one transaction:

```elixir
{:atomic, {_bindings, _constraints, state}} =
  run trace: [:vm] do
    ~AL"count_to 0 3."
  end

state.trace.events |> Enum.reverse() |> AL.Trace.render()
```

`:vm` records each executed instruction, frame, program counter, and registers
before execution, including integer arithmetic fallback events. It preserves
optimized execution when used alone. Raw events are available in
`state.trace.events`, newest first. Failed transactions retain chronological
events in `reason.trace` on the `{:aborted, reason}` result.

`:goals` records reconstructed AL goals. `:domino` records method/clause ports
and constraint evidence. Flags can be combined, but `:goals`, `:domino`, or
active tracepoints select the semantic tracing path, which disables some
optimizations. Use `:vm` alone without tracepoints to inspect optimized JAM.

Send events also show target resolution, cache hits, and lookup fallbacks.
Resolved plans expose the dispatch key, any exact-receiver guard, the selected
provider frame, and clause argument-transfer layouts. Plans live in the current
machine execution segment; mutation/resumption boundaries rebuild this cache.

The JAM renderer abbreviates registers as `R0`, `R1`, and so on, and omits
embedded fallback bodies from instruction lines. For the complete event data,
use `AL.Trace.render(events, format: :raw)`. Rendering does not change the
captured events.

## Compile and inspect a transaction program

```elixir
{:ok, compiled} = AL.compile("count_to 0 3.")
IO.inspect(compiled.ir, pretty: true, limit: :infinity)
IO.inspect(compiled.jam, pretty: true, limit: :infinity)
AL.execute(compiled, AL.Branch.head(), trace: [:vm])
```

Compilation does not execute goals or require Mnesia. The result contains the
root program's IR, JAM instructions (including progress steps), initial register
layout, and retained source. Sends resolve and compile their methods against the
execution branch; the artifact does not include all transitive method bodies or
branch-specific specialization. `AL.eval_source/3` uses the same compile/execute
path.

You can reuse the artifact or pass it to another process running the same code.
Each execution creates a fresh transaction and bindings. This is an in-memory
runtime artifact, not a versioned storage or network format.

Static integer return summaries can be inspected against installed methods:

```elixir
:mnesia.transaction(fn ->
  AL.JAM.Compiler.return_summary(:fibonacci, [:integer, :unknown], AL.Branch.head())
end)
```

Modes include the receiver at position zero. The result reports input modes,
output guarantees, recursive call summaries, and method dependencies. The
initial analysis supports integer receivers and straight-line relational
arithmetic bodies, including recursive sends. Unsupported operations produce
unknown guarantees. These facts apply to successful completed calls; they do
not prove termination or determinism. Summaries are currently inspectable
analysis and do not remove execution guards.

## Benchmarks

The benchmark suites under `bench/` use Benchee. Run a suite with `mix run`, for
example:

```console
mix run bench/succ.exs
mix run bench/succ.exs 50000
mix run bench/fibonacci.exs
mix run bench/length_generate.exs
mix run bench/sudoku.exs --hard
mix run bench/regsm.exs entry 1000 7919
```

Benchmarks run with the default empty trace flag set so they measure execution
rather than construction of retained derivation histories.

Benchee defaults to two seconds of warmup and five seconds of measurement per
scenario. Set `BENCH_WARMUP` and `BENCH_TIME` to non-negative numbers to adjust
those durations. `BENCH_MEMORY_TIME` and `BENCH_REDUCTION_TIME` opt into Benchee's
memory and reduction measurements. The existing `--profile` modes remain
available for targeted `:eprof` runs.

## Working with the live AL node over MCP

The AL owner node starts an MCP server on `http://127.0.0.1:3031/mcp`. Joining
BEAM nodes use the owner's Mnesia tables and do not start competing MCP
listeners. The server is disabled in the test environment.

Add it to Codex with:

```console
codex mcp add almcp --url http://localhost:3031/mcp
```

## Installing into Glamorous Toolkit

The bundled Lepiter notebook **Working with AL in GT** covers bridge setup,
connection checks, object inspection, and troubleshooting. After loading the
baseline below, register it in GT with:

```st
BaselineOfAL loadLepiter
```

For a local Tonel load or a checkout not registered as `AL-Ex` in Iceberg:

```st
BaselineOfAL loadLepiterFrom: '/path/to/AL-Ex'
```

The database is stored in `lepiter/`. Edit its page in GT and include the
resulting files in the same review as related code changes. Registration does
not start an Elixir runtime or execute the notebook's setup snippets.

```st
Metacello new
	repository: 'github://anoma/AL-Ex:base/src/gt';
	baseline: 'AL';
	load
```

If you have an existing bridge with a different version you want to run this without error then run:

```st
Metacello new
	repository: 'github://anoma/AL-Ex:base/src/gt';
	baseline: 'AL';
	load: #dev
```

The standalone allocation benchmark constructs durable objects and value objects
with the same payload, retaining and checking every result. Startup and branch
setup are outside the timer:

```sh
mix run --no-start bench/allocations.exs
AL_ALLOCATION_COUNT=10000 mix run --no-start bench/allocations.exs
```
