# Relational-object programming in AL

## Start from the relation

An AL method head describes a relation among its arguments. Names such as
"input" and "output" may describe a common call mode, but they are not part of
the method's semantics. Keep arguments open when unification or constraints can
solve them later.

Write base and recursive cases as clauses:

```prolog
list >> same_length
| [] [] |.

list >> same_length
| [_ . Xs] [_ . Ys] |
same_length Xs Ys.
```

Do not replace this with a `->` ladder or a host-side length check. The two
clauses are both explanations of the relation and remain available to
backtracking.

## Use clauses for alternatives

Repeated selectors are one ordered, multi-clause method. Separate cases by head
shape and relational guards:

```prolog
list >> map
| [] _Operation [] |.

list >> map
| [Head . Tail] Selector [Mapped . Rest] |
send Head Selector [Mapped],
map Tail Selector Rest.

list >> map
| [Head . Tail] Method [Mapped . Rest] |
isa Method anonymous_method,
run Method [Head, Mapped],
map Tail Method Rest.
```

The alternatives have the same arity. The anonymous-method clause identifies
its object relationally with `isa`; it is not selected by a type test or
argument count. If the selector interpretation fails, backtracking can reach
the executable-value interpretation.

Use a conditional `C -> T ; E` only when this backtracking behavior is not
wanted. It is a soft cut: the first successful condition commits to its branch.
As in Prolog, `C -> T` without an else fails when `C` fails.

## Put behavior in dispatch

When policy differs by kind of object, define or override a method on the
relevant class or metaclass. Avoid a general method that fetches
`class Self ClassName`, walks superclasses, and compares against a list of
special names. That reproduces dispatch manually and usually requires a cut to
hide overlapping branches.

A useful shape is:

```prolog
object >> operation
| Self Args |
validate_operation Self Args,
perform_operation Self Args.

class >> validate_operation
| _Self _Args |.

behaviour >> validate_operation
| _Self _Args |.
```

Custom metaclasses then inherit policy normally, and another class can refine
the protocol without editing a special-case list.

## Preserve constraints

Unification and constraints are the program. Do not eagerly label a variable
just to turn it into an ordinary value. Post `isa`, `in_domain`, bounds, `dif`,
or another constraint and allow later goals to refine it.

Label only at an explicit search boundary where concrete answers are required.
A collection or query planner should retain the derivation that narrowed a
variable before a later method or label split it into answers.

Use `not` as negation as failure, not as a general inequality operator. Prefer
`dif` when two terms must remain different even if either is still open.

## Goal sequences

Goals are separated by commas, and the comma binds loosest, so a conditional
or alternative needs no brackets as one item of a body or block. Every
top-level form ends with `.`. Each side of `->` or `;` is one goal; group
several with a `{...}` block:

```prolog
< By 0 -> fail ; {= Next (+ Count By), set_slot Self count Next}.

= A 1 ; = A 2.

not {class Value anonymous_method, ground Value}.
```

A call's arguments are single terms, so a nested call or arithmetic is
bracketed: `between Self (+ Low 1) High V`. Operators are ordinary names
called in prefix (`= X 1`, `< X 5`), and a constraint disjunction is
`or (= C 1) (= C 2)`. Forms that take goals take blocks:
`findall T R {G}`, `forall {C} {A}`, `lambda [Args] M {G}`.

## Selector values and executable values

A selector is data naming behavior on another receiver. Omit the argument list
when it is empty:

```prolog
send Receiver Selector.
send Receiver Selector Args.
```

A method object is itself executable through its `run` protocol:

```prolog
run Method Args.
```

This applies both to durable method objects returned by `method` and to
`anonymous_method` values. Do not introduce callable syntax, a functor
wrapper, or a public call term. `call Head Body Args` remains an internal
relation for executing stored clause data.

Partial application is immutable value construction:

```prolog
lambda [First, Second, Result] Method {= Result [First, Second]},
add_arg Method a PartiallyApplied,
run PartiallyApplied [b, Result].
```

An updater should read only what it changes or needs:

```prolog
anonymous_method >> add_arg
| Self Arg Updated |
get Self args Args,
concat Args [Arg] UpdatedArgs,
put Self args UpdatedArgs Updated.
```

Do not fetch and reconstruct unrelated `head` and `body` fields.

## Durable objects versus value objects

Durable objects are identities whose slots are command-log-backed state:

```prolog
get Object status Status,
set_slot Object status completed,
set_slots Object #{status => completed, outcome => Outcome}.
```

`set_slot` dispatches validation through the object's class protocol before the
VM records the mutation. Use it for ordinary modeled state.

Value objects are maps. An update returns another value:

```prolog
get Value args Args,
put Value args UpdatedArgs Updated.
```

Their initializer must construct a complete map by unification. A map does not
gain durable identity merely because a slot mutation goal is aimed at it.

## Public protocols versus VM primitives

Use the public relation whenever the receiver is a modeled AL object or value:

- `get` instead of `vm_map_get` or a raw slot read in application code.
- `put` instead of `vm_map_put` for immutable value updates.
- `set_slot`/`set_slots` instead of `vm_set_slot` for durable object behavior.
- `run` instead of exposing stored heads and bodies to callers.

Keep a `vm_*` operation when it is the bottom of that public protocol, when a
serializer/package reconciler must apply exact structure without being
intercepted by the structure it is repairing, or when an example deliberately
tests the primitive against an unclassed identity.

## Representation discipline

AL programs contain no tuples; braces are always blocks of goals. Use:

- lists `[A, B . T]` for ordered positional values and relation records;
- maps `#{key => Value}` for named immutable values;
- classed value maps when the value needs behavior;
- durable objects when identity and history matter.

Internal Elixir modules use tuples for goal encodings, Mnesia rows, and private
return values. Do not leak those encodings into AL source or APIs.
