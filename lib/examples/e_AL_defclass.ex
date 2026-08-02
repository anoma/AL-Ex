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
          defmethod(:ping, [self, :pong]) do
          end
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
end
