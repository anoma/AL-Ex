# AL

AL is a live, ACID, (eventually) bitemporal, relational-object operating system built around an append-only command log. It combines inspiration from:

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
- Constraint solving over finite domains: bounds consistency, `dif`, global constraints like `all_dif` (Régin's algorithm).
- Git-like branching. Fork state, work in isolation, discard or keep.
- Execution tracing. Every run reconstructs a derivation tree: what was called, what was asserted, what it resolved to.

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

**Look inside a live object.**

```elixir
run do
  examine(:object, info)
end
```

**Extend an inherited method**

```elixir
run do
  defclass :animal, super: :object do
    defmethod(:describe, [self, :i_am_animal]) do
    end
  end

  defclass :pet, super: :animal do
    defmethod(:describe, [self, d]) do
      call_next_method(self, [parent])
      unify(d, [:i_am_pet, parent])
    end
  end

  new(:pet, rex)
  describe(rex, result)
end
```

**Run a method backwards.**

```elixir
run do
  factorial(n, 120)
end
```

**Propagate constraints about and between objects**

```elixir
run do
  defclass :rectangle, super: :value, ivars: [:width, :height, :perimeter] do
    defmethod(:init, [self, args, new]) do
      slot_get(args, :width, w)
      slot_get(args, :height, h)
      slot_get(args, :perimeter, p)
      eq(p, 2 * w + 2 * h)
      unify(new, %{class: :rectangle, width: w, height: h, perimeter: p})
    end

    defmethod(:get_slot, [self, k, v]) do
      vm_map_get(self, k, v)
    end

    defmethod(:area, [self, result]) do
      get_slot(self, :width, w)
      get_slot(self, :height, h)
      vm_is(result, w * h)
    end
  end

  new(:rectangle, %{width: w, height: 3, perimeter: 16}, r)
  area(r, a)
end
```

**Infer an object's identity from its class and a slot**

```elixir
run do
  defclass :vehicle, super: :object do
  end

  defclass :car, super: :vehicle do
  end

  defclass :bicycle, super: :vehicle do
  end

  defclass :fire_hydrant, super: :object do
  end

  set_slots(:car, %{color: :red})
  set_slots(:bicycle, %{color: :blue})
  set_slots(:fire_hydrant, %{color: :red})

  new(:car, my_car)
  new(:bicycle, my_bike)
  new(:fire_hydrant, hydrant)

  class(x, :vehicle)
  get_slot(x, :color, :red)
end
```

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
