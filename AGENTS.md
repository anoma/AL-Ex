# AL repository instructions

AL is an object-oriented logic language. Write AL programs as relations and
object protocols, not as Elixir control flow expressed through AL syntax.

## Language rules

- AL surface syntax does not support Elixir tuple literals. Represent AL data
  with lists, maps, or classed value objects. Tuples are reserved for internal
  Elixir/VM encodings.
- Multiple clauses of the same selector inside one `defclass` are supported and
  expected. Use clauses, head patterns, unification, constraints, and `isa` to
  express alternatives instead of inspecting argument count or manually
  switching on types.
- Declare ordinary classes, value classes, metaclasses, and categories with
  `defclass`. Use raw `new(:class, ...)` construction only while implementing or
  testing the class protocol itself.
- Let method dispatch express object policy. Prefer an override on the relevant
  class or metaclass over tests such as `class(...)`, superclass walks, or
  special-class lists inside a general method.
- Preserve useful modes. Do not ground, label, cut, or commit merely to make an
  implementation easier when the relation can remain bidirectional.
- A selector value is applied with `send(receiver, selector)` when it takes no
  arguments, or `send(receiver, selector, args)` otherwise. A method
  object or `:anonymous_method` value is executed with `run(method, args)`.
  Do not invent Elixir-style callable syntax, functor wrappers, or public call
  terms.
- Durable objects and value objects have different update protocols. Use
  `get`/`set_slot`/`set_slots` for modeled durable state and `get`/`put` for an
  updated classed map value. Do not reconstruct unrelated value slots merely to
  update one field.
- Use `vm_*` operations only when implementing the corresponding public
  protocol, performing exact structural reconciliation, or deliberately testing
  the primitive. Ordinary AL program code should use the public relation.
- Do not add comments. Prefer names, clauses, and observable examples that make
  the program explain itself.

## Runtime policy

- VM-internal changes do not require image, replay, command-log, or stored-state
  compatibility unless the user explicitly requests it. Update the current
  runtime coherently; do not add migrations or compatibility branches by
  default.
- Never remove the shared `.mnesiastore` for test isolation. Use the repository's
  isolated test helper.

For AL programs, packages, examples, or bootstrap surface code, read
`.agents/skills/al-practices/SKILL.md`. For interpreter, dispatch, persistence,
tracing, or serialisation internals, read
`.agents/skills/al-internals/SKILL.md` as well.
