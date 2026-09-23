# Relational-object programming in AL

## Start from the relation

An AL method head describes a relation among its arguments. Names such as
"input" and "output" may describe a common call mode, but they are not part of
the method's semantics. Keep arguments open when unification or constraints can
solve them later.

Write base and recursive cases as clauses:

```elixir
defmethod(:list, :same_length, [[], []])

defmethod(:list, :same_length, [[_ | xs], [_ | ys]]) do
  same_length(xs, ys)
end
```

Do not replace this with an `implies` ladder or an Elixir-side length check. The
two clauses are both explanations of the relation and remain available to
backtracking.

## Use clauses for alternatives

Repeated selectors are one ordered, multi-clause method, including inside a
`defclass`. Separate cases by head shape and relational guards:

```elixir
defmethod(:list, :map, [[], _operation, []])

defmethod(:list, :map, [[head | tail], selector, [mapped | rest]]) do
  send(head, selector, [mapped])
  map(tail, selector, rest)
end

defmethod(:list, :map, [[head | tail], method, [mapped | rest]]) do
  isa(method, :anonymous_method)
  run(method, [head, mapped])
  map(tail, method, rest)
end
```

The alternatives have the same arity. The anonymous-method clause identifies
its object relationally with `isa`; it is not selected by an Elixir type test or
argument count. If the selector interpretation fails, backtracking can reach
the executable-value interpretation.

Use `implies` only when this backtracking behavior is not wanted. It is a soft
cut: the first successful condition commits to its branch.

## Put behavior in dispatch

When policy differs by kind of object, define or override a method on the
relevant class or metaclass. Avoid a general method that fetches `class(self,
class_name)`, walks superclasses, and compares against a list of special names.
That reproduces dispatch manually and usually requires a cut to hide overlapping
branches.

A useful shape is:

```elixir
defmethod(:object, :operation, [self, args]) do
  validate_operation(self, args)
  perform_operation(self, args)
end

defmethod(:class, :validate_operation, [_self, _args])
defmethod(:behaviour, :validate_operation, [_self, _args])
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

## Selector values and executable values

A selector is data naming behavior on another receiver. Omit the argument list
when it is empty:

```elixir
send(receiver, selector)
send(receiver, selector, args)
```

A method object is itself executable through its `run` protocol:

```elixir
run(method, args)
```

This applies both to durable method objects returned by `method/3` and to
`:anonymous_method` values. Do not introduce `callable.(...)`, a functor wrapper,
or a public call term. `call(head, body, args)` remains an internal relation for
executing stored clause data.

Partial application is immutable value construction:

```elixir
new(
  :anonymous_method,
  %{args: [], head: [first, second, result], body: [result = [first, second]]},
  method
)

add_arg(method, :a, partially_applied)
run(partially_applied, [:b, result])
```

An updater should read only what it changes or needs:

```elixir
defmethod(:add_arg, [self, arg, updated]) do
  get(self, :args, args)
  concat(args, [arg], updated_args)
  put(self, :args, updated_args, updated)
end
```

Do not fetch and reconstruct unrelated `head` and `body` fields.

## Durable objects versus value objects

Durable objects are identities whose slots are command-log-backed state:

```elixir
get(object, :status, status)
set_slot(object, :status, :completed)
set_slots(object, %{status: :completed, outcome: outcome})
```

`set_slot` dispatches validation through the object's class protocol before the
VM records the mutation. Use it for ordinary modeled state.

Value objects are maps. An update returns another value:

```elixir
get(value, :args, args)
put(value, :args, updated_args, updated)
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

AL programs do not contain Elixir tuple literals. Use:

- lists for ordered positional values and relation records;
- maps for named immutable values;
- classed value maps when the value needs behavior;
- durable objects when identity and history matter.

Internal Elixir modules may use tuples for goal encodings, Mnesia rows, and
private return values. Do not leak those encodings into AL surface examples or
APIs.
