# AL

AL is a live, ACID, (eventually) bitemporal, relational-object operating system built around an append-only command log. It combines inspiration from:

- XTDB

- GlamorousToolkit/Pharo

- Git

- PROLOG/Logtalk

- LISP

- BEAM

- Urbit


The goal of the system is to be the first truly principled object-oriented PROLOG, and the personal computing environment of the future.
This runtime is the first version of AL, written in Elixir. The irony of the first Erlang interpreter having been written in PROLOG is not lost on us.

## Features

- Live Smalltalk-style objects, defined relationally. No more faux-ADTs. Define protocols and their implementations. Mix and match at your leisure. With bidirectional method resolution informed by WAM semantics.
- Shutdown your system, continue later. All transactions are backed up by an on-disk database, hydrated at startup.
- ACID transactions ensure your work is safe and easy to reason about.
- CLP over finite domains, *including* over object IDs
- Git-Like branching behaviour. Fork your system at different points in the system's history.

And to come:

- Bitemporality features: Query objects as of certain times, working with system and business time separately

For discussion of the design philosophy of AL and resources that were consulted during its design, please see: 
https://forum.anoma.net/t/design-philosophy-of-al-bibliography/2698

## Quickstart

Install from terminal using `iex -S mix` or as a mix dependency.
From IEx, you can run `require AL`.

`lib/examples` contains examples.
`lib/AL/package` contains the bundled packages (the `bootstrap` package is the foundational one).
`lib/AL` contains the runtime code.

## Some Recipes

- Use `examine(:my_object_id_here, info)` in order to get quick information about an object via its ID, such as its class(es!), superclass(es!), methods, and in the case of methods, relevant clauses.

- Have a class import the `value` category through `import(:my_class, :value)` in order to support ephemeral objects that don't get added to the database but that can be generated as structures. 

- Use `mix al.reset --yes` for a quick wipe

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
	repository: 'github://anoma/AL-Ex:main/src';
	baseline: 'AL';
	load
```

If you have an existing bridge with a different version you want to run this without error then run:

```st
Metacello new
	repository: 'github://anoma/AL-Ex:main/src';
	baseline: 'AL';
	load: #dev
```
