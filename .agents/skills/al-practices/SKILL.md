---
name: al-practices
description: Design, write, refactor, and debug relational-object AL programs, packages, bootstrap methods, and examples. Use for defclass, defmethod, run blocks, collection protocols, value objects, anonymous methods, AL surface syntax, and example-driven verification. Use al-internals as well when changing the interpreter or durable runtime.
---

# AL practices

AL is an object-oriented logic language. A good AL method states a relation and
lets unification, constraints, clause choice, backtracking, and object dispatch
do the work. Do not translate an imperative Elixir algorithm line by line.

For any nontrivial AL method, class, collection protocol, or refactor, read
[references/relational-object-programming.md](references/relational-object-programming.md).
For tests, Mnesia isolation, tracing, bootstrap reloads, or async examples, read
[references/workflow.md](references/workflow.md).

## Design checklist

Before writing a method, identify:

1. The relation represented by its head.
2. The useful input/output modes it should preserve.
3. Which alternatives are separate clauses.
4. Which facts are constraints that may remain attached to open variables.
5. Whether behavior belongs in dispatch on a class instead of a conditional.
6. Whether the result is durable state or a new immutable value.

Prefer the smallest set of goals that states those facts. Treat clause order,
cut, `implies`, labeling, and side effects as semantic commitments, not routine
control-flow tools.

## Core surface rules

- AL has no tuple literals. Use lists for positional relational data, maps for
  named value data, and value classes when behavior belongs with that data.
- Multiple `defmethod` entries with the same selector are valid inside one
  `defclass`. They form ordered clauses of one method. Use this for base cases,
  recursive cases, and relational alternatives.
- Use `defclass` for ordinary class, value-class, metaclass, and category
  declarations. Reserve raw `new(:class, ...)` construction for implementation
  or tests of the class protocol itself.
- Inside `defclass`, methods use `defmethod(selector, head) do ... end`. Keep an
  explicit `do ... end`, including for an empty body. Top-level definitions use
  `defmethod(class, selector, head)`.
- Method and `run` bodies are sequences of goals. `forall` and `findall` take a
  `do ... end` goal body. `not` and low-level `call` take a list of goals.
- `implies` is committed if/then/else: it keeps the first successful condition
  and discards its remaining alternatives. If no condition matches and no
  `:else` is present, it succeeds vacuously. Use explicit `:else -> fail` when
  failure is intended.
- Use `cut` only when the relation intentionally commits to choices made in the
  current call scope.

## Objects and executable values

- Normal calls dispatch a selector through the receiver. When the selector is a
  value, use `send(receiver, selector, args)`.
- Method objects and `:anonymous_method` values implement `run(args)`. Execute
  them with `run(method, args)`.
- An `:anonymous_method` is a classed value object with `args`, `head`, and
  `body`. `add_arg` returns an updated value; it does not mutate the original.
  The loaded arguments and provided arguments are concatenated, unified with
  the head, and then the body runs.
- When a protocol accepts either a selector or an anonymous method, keep them as
  clauses of the same arity. Use `send` for the selector clause and constrain
  the executable-value clause with `isa(method, :anonymous_method)` before
  calling `run`.
- `call(head, body, args)` is the low-level relation used to apply stored clause
  data. It is not the public representation of an anonymous callable.

## State and values

- A durable object has an identity and projected slots. Read it with `get`; write
  it with `set_slot` or `set_slots` so its class protocol validates the write.
- A map-shaped value object is immutable. Read it with `get`; produce an updated
  value with `put`. Read only the slots required to compute that update.
- A value class's `init` constructs its result by unifying with a complete map.
  Do not use durable slot mutation on a map scaffold.
- Prefer `get`, `put`, `set_slot`, and `set_slots` in program code. Use
  `vm_map_get`, `vm_map_put`, or `vm_set_slot` only at the implementation or
  structural-reconciliation boundary.

## Verification

Examples are executable specifications. Add or update the smallest example that
observes the intended relation, run it with the isolated helper, then run the
full suite when bootstrap or shared protocols changed. Assert answers and
constraints rather than private tables or implementation steps.
