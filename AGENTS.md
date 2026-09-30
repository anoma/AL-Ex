# AL repository instructions

AL is an object-oriented logic language. Write AL programs as relations and
object protocols, not as Elixir control flow expressed through AL syntax.

## Syntax

- AL has its own Prolog-like syntax, read by `AL.Syntax` straight into the
  `AL.Goal` structs the interpreter runs. The grammar is in
  `lib/AL/syntax.bnf`. Variables are capitalised (`Self`, `_`), atoms are
  lowercase or quoted (`point`, `'Hello'`), `[H . T]` is a list,
  `#{key => V}` is a map, and `{G1, G2}` is a block of goals.
- A call is juxtaposition: `sel Recv Arg1 Arg2` sends `sel` to `Recv`. Call
  arguments are single terms, so a nested call is bracketed:
  `between Self (+ Low 1) High V`. `(foo)` is a goal with no arguments.
- Operators are ordinary names called in prefix: `= X 1`, `< X 5`,
  `= Y (+ X 1)`, `or (= C 1) (= C 2)`. The only infix forms are `,`, `;`,
  `->`, and the list tail `.`. A minus touching a number is a negative
  literal (`-1`).
- Every top-level form ends with `.`. Goals are separated by commas.
- A class is declared with `@name #{super => S, ivars => [#{name => x}]}.`. Ivars
  are a list of maps with a `name:`. Declaring an existing name again replaces
  its declaration.
- A method clause is written with the head on its own line:

  ```
  list >> fold_left
  | [H . T] Func Acc Result |
  run Func [Acc, H, Next],
  fold_left T Func Next Result.
  ```

  Bodies are flush left under the head, a class's options map goes on the
  line after `@name`, and a map or list wider than 80 columns is written one
  entry per line; `AL.Syntax.Printer` prints this layout.
  The head is the selector's arguments between bars, and `. Rest` collects
  the remaining ones. A clause with no body ends after its head:
  `| [] _Func Acc Acc |.`
- The clauses one source gives for an owner and selector are that method's
  whole definition: reading them clears the method's earlier clauses, as a
  Prolog reconsult does. To add a clause to a method defined elsewhere, use
  `defmethod Owner Sel [Head] {Body}`.
- `C -> T ; E` is a committed conditional (`C -> T` alone fails when `C`
  fails), `A ; B` is a backtracking alternative, and `A or B` is a disjunctive
  constraint. Either side of `->` or `;` is one goal or a `{...}` block.
- Forms that take goals take blocks: `findall T R {G}`, `forall {C} {A}`,
  `not {G}`, `lambda [Args] M {G}`, `spawn {G}`.
- Comments start with `#`; `#{` always opens a map.
- The only Elixir in AL is its AST. Transaction programs live in
  `priv/programs/*.al` and start with `defprogram name #{version => V, deps => [...]}.`.
  Elixir code embeds AL only as `run do ~AL"""...""" end` (where `^name` pins
  an Elixir value) or text passed to `AL.eval_source/3`. Definition files
  (`*.class.al`, `*.extension.al`) are AL source too: leading `#` comment
  lines, then `@name #{...}.` for a class or `@+name #{super => [...]}.` for an
  extension of a class owned elsewhere, then that owner's method clauses. In an Elixir `"..."` string,
  write an AL map as `\#{...}`; `~AL` and `~S` do not interpolate.
- AL has no tuples. Represent AL data with lists, maps, or classed value
  objects. Tuples are reserved for internal Elixir/VM encodings.

## Language rules

- Multiple clauses of the same selector are supported and expected. Use clauses, head patterns, unification, constraints, and `isa` to
  express alternatives instead of inspecting argument count or manually
  switching on types.
- Declare ordinary classes, value classes, metaclasses, and categories with an
  `@name` class declaration. Use raw `new class ...` construction only while
  implementing or testing the class protocol itself.
- Let method dispatch express object policy. Prefer an override on the relevant
  class or metaclass over tests such as `class X C`, superclass walks, or
  special-class lists inside a general method.
- Preserve useful modes. Do not ground, label, cut, or commit merely to make an
  implementation easier when the relation can remain bidirectional.
- A selector value is applied with `send Receiver Selector` when it takes no
  arguments, or `send Receiver Selector Args` otherwise. A method object or
  `anonymous_method` value is executed with `run Method Args`. Do not invent
  callable syntax, functor wrappers, or public call terms.
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
