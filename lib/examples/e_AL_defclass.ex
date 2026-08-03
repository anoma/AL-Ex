defmodule Examples.ALDefclass do
  @moduledoc """
  I provide examples for `defclass` — bundles `new(metaclass, …)` + one
  `import` per category + one `defmethod` per method into one declaration.
  Lowers to a single `:defclass` OApply, same as `defmethod` lowers to
  `:defmethod` — sequencing lives in AL (bootstrap.ex), not the syntax.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example defclass_declares_class_imports_and_methods() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:category, %{name: :widget_behaviour}, _)

        defmethod(:widget_behaviour, :describe, [self, :a_widget])

        defclass :widget,
          super: :value,
          ivars: [:label],
          categories: [:widget_behaviour] do
          defmethod(:init, [self, args, new]) do
            vm_map_get(args, :label, l)
            unify(new, %{class: :widget, label: l})
          end

          defmethod(:label, [self, l]) do
            vm_map_get(self, :label, l)
          end
        end

        new(:widget, %{label: :ok}, w)
        label(w, l)
        describe(w, kind)
      end

    assert Map.get(bindings, :"$l") == :ok
    assert Map.get(bindings, :"$kind") == :a_widget
    :ok
  end

  # metaclass defaults to :class — same as new(:class, %{...}, _) by hand.
  example defclass_defaults_metaclass_to_class() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        defclass :durable_thing, super: :object, ivars: [] do
        end

        new(:durable_thing, instance)
        vm_class(instance, class)
      end

    assert Map.get(bindings, :"$class") == :durable_thing
    assert is_atom(Map.get(bindings, :"$instance"))
    :ok
  end

  # metaclass: :object -- the class itself is a plain durable object, no
  # per-instance construction.
  example defclass_supports_metaclass_override() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        defclass :singleton_thing, metaclass: :object, super: :object do
          defmethod(:ping, [self, :pong])
        end

        ping(:singleton_thing, reply)
      end

    assert Map.get(bindings, :"$reply") == :pong
    :ok
  end

  # categories/ivars/methods can all be omitted — empty class body is legal.
  example defclass_with_no_categories_or_methods() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        defclass :bare_thing, super: :object do
        end

        new(:bare_thing, instance)
        vm_class(instance, class)
      end

    assert Map.get(bindings, :"$class") == :bare_thing
    :ok
  end

  # Regression: two methods-list entries sharing a selector used to have the
  # second's retract-before-define step wipe out the first's fresh clause --
  # defclass now retracts every entry's prior clauses in one pass before
  # defining any of them, so both survive.
  example defclass_supports_multiple_clauses_on_one_selector() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        defclass :multi_clause_thing, super: :object do
          defmethod(:pick, [self, :a, :first])

          defmethod(:pick, [self, :b, :second])
        end

        new(:multi_clause_thing, instance)
        pick(instance, :a, r1)
        pick(instance, :b, r2)
      end

    assert Map.get(bindings, :"$r1") == :first
    assert Map.get(bindings, :"$r2") == :second
    :ok
  end

  # Regression: a bodyless defmethod(name, head) entry inside defclass used
  # to crash lowering (methods-list extraction only matched the 3-element
  # with-body shape).
  example defclass_supports_bodyless_methods() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        defclass :bodyless_thing, super: :value do
          defmethod(:known, [42])
        end

        new(:bodyless_thing, x)
        unify(x, 42)
      end

    assert Map.get(bindings, :"$x") == 42
    :ok
  end
end
