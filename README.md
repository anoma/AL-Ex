# AL

AL is a live, ACID, bitemporal, relational-object operating system built around an append-only command log. It combines inspiration from:

- XTDB

- GlamorousToolkit/Pharo

- Git

- PROLOG/Logtalk

- LISP

- BEAM

- Urbit


The goal of the system is to merge the ideas of the relational paradigm and of the metaobject protocol, and, as a north star, to be the personal computing environment of the future.
This runtime is the prototypical version of AL, written in Elixir. The irony of the first Erlang interpreter having been written in PROLOG is not lost on us.

## Features

- Objects defined relationally, with multiple inheritance and bidirectional dispatch. An unbound receiver turns a call into a search.
- Durable by default. Every change is logged to disk. Restart and continue where you left off.
- ACID transactions.
- Constraint solving over finite domains: bounds consistency, `dif`, global constraints like `all_dif` (Régin's algorithm). Objects can be reasoned about via constraints.
- Git-like branching. Fork state, work in isolation, discard or keep.
- Execution tracing. Every run reconstructs a derivation tree: what was called, what was asserted, what it resolved to.
- Nascent bitemporality features: Query objects as of certain times, working with system and business time separately

For discussion of the design philosophy of AL and resources that were consulted during its design, please see: 
https://forum.anoma.net/t/design-philosophy-of-al-bibliography/2698

## Quickstart

Install from terminal using `iex -S mix` or as a mix dependency.
From IEx, you can run `require AL`.

`lib/examples` contains examples.
`lib/AL/transaction_program` contains the bundled transaction programs (`bootstrap` establishes the language).
`lib/AL` contains the runtime code.
`priv/packages` contains the packages that will be installed upon image setup.

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

Benchmarks run with `trace_mode: :no_trace` so they measure execution rather
than construction of retained derivation histories.

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
