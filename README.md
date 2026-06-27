# AL

AL is a live, ACID, (eventually) bitemporal, relational-object operating system built around an append-only command log. It combines inspiration from:

- XTDB

- GlamorousToolkit/Pharo

- Git

- PROLOG

- LISP

- BEAM

- Urbit


The goal of the system is to be the first truly principled object-oriented PROLOG, and the personal computing environment of the future.
This runtime is the first version of AL, written in Elixir. The irony of the first Erlang interpreter having been written in PROLOG is not lost on us.

## Features

- Live Smalltalk-style objects, defined relationally. No more faux-ADTs. Define protocols and their implementations. Mix and match at your leisure.
- Bidirectional Execution thanks to WAM semantics.
- Shutdown your system, continue later. All transactions are backed up by an on-disk database, hydrated at startup.
- ACID transactions ensure your work is safe and easy to reason about.
- Constraint Processing

And to come:

- Bitemporality features: Model temporal systems. Spin off new branches of your system at different points in time and move between them easily.

For discussion of the design philosophy of AL and resources that were consulted during its design, please see: 
https://forum.anoma.net/t/design-philosophy-of-al-bibliography/2698

## Getting Started

Install from terminal using `iex -S mix` or as a mix dependency.
From IEx, you can run `require AL`.

`lib/examples` contains examples.
`lib/AL/package` contains the bundled packages (the `bootstrap` package is the foundational one).
`lib/AL` contains the runtime code.

Tips:

- Use `examine(:my_object_id_here, info)` in order to get quick information about an object via its ID, such as its class(es!), superclass(es!), methods, and in the case of method objects, relevant clauses.

## Installing into Glamorous Toolkit

```st
Metacello new
	repository: 'github://anoma/anoma-level-elixir-prototype:mariari/branch-datatype/src';
	baseline: 'AL';
	load
```
