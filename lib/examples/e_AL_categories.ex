defmodule Examples.ALCategories do
  @moduledoc """
  I provide examples for `:object :import` — binding a shared implementation
  onto a class without creating a `super` edge, AL's answer to Logtalk-style
  categories.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  # `import` attaches methods for a class's *instances* to resolve, the same way
  # any other `defmethod(SomeClass, ...)` does — sending directly to the class
  # atom itself doesn't work, by design, the same as any other class-defined
  # method (a class isn't an instance of itself).
  example import_shares_implementation_without_inheritance() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:category, %{name: :greeter_behaviour}, _)

        defmethod(:greeter_behaviour, :greet, [self, :hello]) do
        end

        new(:class, %{name: :cat_a, super: :object, ivars: []}, _)
        new(:class, %{name: :cat_b, super: :object, ivars: []}, _)

        import(:cat_a, :greeter_behaviour)
        import(:cat_b, :greeter_behaviour)

        new(:cat_a, _, instance_a)
        new(:cat_b, _, instance_b)

        greet(instance_a, greeting_a)
        greet(instance_b, greeting_b)
      end

    assert Map.get(bindings, :"$greeting_a") == :hello
    assert Map.get(bindings, :"$greeting_b") == :hello
    :ok
  end

  example import_creates_no_super_edge() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:category, %{name: :shared_behaviour}, _)

        defmethod(:shared_behaviour, :trait, [self, :shared_trait]) do
        end

        new(:class, %{name: :import_a, super: :object, ivars: []}, _)
        new(:class, %{name: :import_b, super: :object, ivars: []}, _)

        import(:import_a, :shared_behaviour)
        import(:import_b, :shared_behaviour)

        not [super(:import_a, :import_b)]
        not [super(:import_b, :import_a)]
        not [super(:import_a, :shared_behaviour)]

        unify(unrelated, true)
      end

    assert Map.get(bindings, :"$unrelated") == true
    :ok
  end

  example category_is_reflectively_queryable() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:category, %{name: :reflect_behaviour}, _)
        class(:reflect_behaviour, kind)
      end

    assert Map.get(bindings, :"$kind") == :category
    :ok
  end
end
