---
name: al-practices
description: Design, write, refactor, and debug relational-object AL programs, packages, bootstrap methods, and examples. Use for class declarations, methods, run blocks, collection protocols, value objects, anonymous methods, AL surface syntax, and example-driven verification. Use al-internals as well when changing the interpreter or durable runtime.
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

If a program seems to need a new VM goal, `vm_*` operation, or native, stop
and ask the user first; do not add one without explicit permission.

Prefer the smallest set of goals that states those facts. Treat clause order,
cut, `->`, labeling, and side effects as semantic commitments, not routine
control-flow tools.

## Core surface rules

- AL has its own Prolog-like syntax; the grammar is `lib/AL/syntax.bnf`.
  Variables are capitalised (`Self`, `_`), atoms are lowercase or quoted,
  `[H . T]` is a list, `#{key => V}` is a map, and `{G1, G2}` is a block of
  goals. Comments start with `#`.
- A call is juxtaposition: `sel Recv Arg1 Arg2` sends `sel` to `Recv`.
  Arguments are single terms, so nested calls and arithmetic are bracketed:
  `between Self (+ Low 1) High V`. `(foo)` is a goal with no arguments.
- Operators are ordinary names called in prefix: `= X 1`, `< X 5`,
  `= Y (+ X 1)`, `or (= C 1) (= C 2)`. The only infix forms are `,`, `;`,
  `->`, and the list tail `.`.
- Goals are separated by commas and every top-level form ends with `.`.
- AL has no tuples. Use lists for positional relational data, maps for named
  value data, and value classes when behavior belongs with that data.
- Transaction programs are `priv/programs/*.al` files that start with
  `defprogram name #{version => V, deps => [...]}.`. Elixir code embeds AL only as
  `run do ~AL"""...""" end` (where `^name` pins an Elixir value) or as text
  for `AL.eval_source/3`. Package definition files are AL source: an `@name`
  class or `@+name #{super => [...]}.` extension declaration followed by that
  owner's method clauses. Inside an Elixir
  `"..."` string an AL map is written `\#{...}`.
- A method clause is `owner >> sel` followed by its head on its own line,
  `| Self Arg . Rest |`, and then its body goals; it ends with `.`. A clause
  without a body ends after its head: `| [] [] |.`. Several clauses with the
  same selector form ordered clauses of one method. Use this for base cases,
  recursive cases, and relational alternatives.
- The clauses one source gives for an owner and selector are the method's
  whole definition: reading them clears its earlier clauses, as a Prolog
  reconsult does, and keeps the method's id. Add a clause to a method defined
  elsewhere with `defmethod Owner Sel [Head] {Body}`.
- Declare ordinary classes, value classes, metaclasses, and categories as
  `@name #{super => object, ivars => [#{name => count}]}.`. Ivars are a list of
  maps with a `name:`. Declaring an existing name again replaces its
  declaration and keeps its methods. Reserve raw `new class ...` construction
  for implementation or tests of the class protocol itself.
- `C -> T ; E` is a committed conditional: it keeps the first successful
  condition and discards its remaining alternatives. As in Prolog, `C -> T`
  without an else fails when `C` fails; write `C -> T ; pass` when it should
  succeed. `A ; B` is a backtracking alternative. Each side is one goal or a
  `{...}` block.
- Forms that take goals take blocks: `findall T R {G}`, `forall {C} {A}`,
  `not {G}`, `lambda [Args] M {G}`, `spawn {G}`.
- Use `cut` only when the relation intentionally commits to choices made in the
  current call scope.

## Objects and executable values

- Normal calls dispatch a selector through the receiver. When the selector is a
  value, use `send Receiver Selector` with no arguments, or
  `send Receiver Selector Args` otherwise.
- Method objects and `anonymous_method` values implement `run`. Execute them
  with `run Method Args`.
- An `anonymous_method` is a classed value object with `args`, `head`, and
  `body`. `add_arg` returns an updated value; it does not mutate the original.
  The loaded arguments and provided arguments are concatenated, unified with
  the head, and then the body runs.
- When a protocol accepts either a selector or an anonymous method, keep them as
  clauses of the same arity. Use `send` for the selector clause and constrain
  the executable-value clause with `isa Method anonymous_method` before
  calling `run`.
- `call Head Body Args` is the low-level relation used to apply stored clause
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
