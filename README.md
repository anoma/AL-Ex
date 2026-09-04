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
`lib/AL/package` contains the bundled packages (the `bootstrap` package is the foundational one).
`lib/AL` contains the runtime code.

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

## Installing into Glamorous Toolkit

```st
Metacello new
	repository: 'github://anoma/AL-Ex:base/src';
	baseline: 'AL';
	load
```

If you have an existing bridge with a different version you want to run this without error then run:

```st
Metacello new
	repository: 'github://anoma/AL-Ex:base/src';
	baseline: 'AL';
	load: #dev
```
