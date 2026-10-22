defmodule Examples.ALPlanAssumptions do
  use ExExample
  import ExUnit.Assertions
  alias AL.JAM.IR.{Assumptions, Call, Plan}

  defp install_protocol() do
    branch = %AL.Branch{id: Examples.Support.branch()}

    assert %AL{result: {:atomic, _}} =
             AL.run(
               ~S"""
               @assumption_probe #{super => value}.
               assumption_probe >> capture
               | Self Receiver Value |
               payload Self Value,
               = Receiver Self.
               assumption_probe >> payload
               | Self Value |
               get Self payload Value.
               assumption_probe >> retag
               | Self Key Output |
               = Key class,
               payload Self Output.
               assumption_probe >> inspect_pair
               | _Self Left Right A B |
               payload Left A,
               payload Right B.
               @assumption_other #{super => value}.
               assumption_other >> payload
               | Self Value |
               get Self alternate Value.
               list >> assumption_walk
               | [] [] |.
               list >> assumption_walk
               | [Value . Tail] [Output . Rest] |
               assumption_identity [] Value Item,
               payload Item Output,
               assumption_walk Tail Rest.
               list >> assumption_head
               | [Head . _Tail] Output |
               assumption_identity [] Head Output.
               list >> assumption_identity
               | _Self Value Output |
               = Output Value.
               list >> assumption_echo
               | Self Output |
               assumption_identity [] Self Output.
               """,
               branch
             )

    branch
  end

  defp selected(receiver, selector, branch, arguments \\ []) do
    assert {:atomic, {compiled, _assumptions}} =
             :mnesia.transaction(fn ->
               {:ok, _, method} = AL.Dispatch.target(receiver, selector, branch)
               original = AL.JAM.Compiler.fetch_method(method, branch)
               Plan.select(original, receiver, selector, arguments, method, branch)
             end)

    compiled
  end

  defp answer(source, branch, opts) do
    case AL.run(source, branch, opts) do
      %AL{result: {:atomic, {bindings, constraints, _}}} -> {:ok, bindings, constraints}
      %AL{result: {:aborted, _}} -> :failure
    end
  end

  example one_argument_has_several_requirements_and_unused_facts_do_not_split_plans() do
    branch = install_protocol()

    assert %AL{result: {:atomic, _}} =
             AL.run(
               ~S"""
               assumption_probe >> read_selected
               | Self _Ignored Output |
               get Self selected Key,
               get Self Key Output.
               assumption_probe >> read_other
               | _Self Other Ignored Output |
               read_selected Other Ignored Output.
               """,
               branch
             )

    first = %{class: :assumption_probe, selected: :payload, payload: :first, tag: :a}
    second = %{first | payload: :second, tag: :b}
    third = %{class: :assumption_probe, selected: :alternate, alternate: :third}
    output = AL.Var.var("Output")
    call = Call.new(first, :read_selected, [:unused, output])

    assert {:atomic, %Plan{assumptions: requirements, compiled: {_, _}}} =
             :mnesia.transaction(fn -> Plan.compile(call, branch) end)

    assert requirements == [
             %{class: :assumption_probe, fields: %{selected: %{value: :payload}}},
             %{},
             %{}
           ]

    other_call = Call.new(first, :read_other, [second, :unused, output])

    assert {:atomic, %Plan{assumptions: other_requirements}} =
             :mnesia.transaction(fn -> Plan.compile(other_call, branch) end)

    assert other_requirements == [%{} | requirements]

    assert Assumptions.accepts?(requirements, Call.new(second, :read_selected, [7, output]))
    refute Assumptions.accepts?(requirements, Call.new(third, :read_selected, [7, output]))

    compiled = selected(first, :read_selected, branch, [:unused, output])
    assert selected(second, :read_selected, branch, [[1, 2, 3], output]) == compiled
    refute selected(third, :read_selected, branch, [:unused, output]) == compiled

    source = ~S"""
    findall [Receiver, Output] Answers {
      member [First, Second, Third] Receiver,
      read_selected Receiver Ignored Output
    }.
    """

    bindings = %{"First" => first, "Second" => second, "Third" => third}
    result = answer(source, branch, bindings: bindings)

    assert {:ok, %{"$Answers" => [[^first, :first], [^second, :second], [^third, :third]]}, _} =
             result

    assert result == answer(source, branch, bindings: bindings, trace: [:domino])

    for source <- [
          ~S"read_selected #{class => assumption_probe, selected => Key, payload => Value} Ignored Output, = Key payload, = Value 7.",
          ~S"in_domain Value [7,8], read_selected #{class => assumption_probe, selected => payload, payload => Value} Ignored Output, = Output 7.",
          ~S"read_selected #{class => assumption_probe, selected => absent, payload => 7} Ignored Output."
        ] do
      assert answer(source, branch, []) == answer(source, branch, trace: [:domino])
    end
  end

  example nested_value_objects_require_the_childs_class_without_freezing_its_payload() do
    branch = install_protocol()

    assert %AL{result: {:atomic, _}} =
             AL.run(
               ~S"""
               assumption_probe >> child_payload
               | Self Output |
               get Self child Child,
               payload Child Output.
               """,
               branch
             )

    first = %{class: :assumption_probe, child: %{class: :assumption_probe, payload: :first}}
    second = %{first | child: %{class: :assumption_probe, payload: :second, tag: :different}}
    third = %{first | child: %{class: :assumption_other, alternate: :third}}
    output = AL.Var.var("Output")

    assert {:atomic, %Plan{assumptions: requirements}} =
             :mnesia.transaction(fn ->
               Plan.compile(Call.new(first, :child_payload, [output]), branch)
             end)

    assert requirements == [
             %{class: :assumption_probe, fields: %{child: %{class: :assumption_probe}}},
             %{}
           ]

    compiled = selected(first, :child_payload, branch, [output])
    assert selected(second, :child_payload, branch, [output]) == compiled
    refute selected(third, :child_payload, branch, [output]) == compiled

    source = ~S"""
    findall [Receiver, Output] Answers {
      member [First, Second, Third] Receiver,
      child_payload Receiver Output
    }.
    """

    bindings = %{"First" => first, "Second" => second, "Third" => third}
    result = answer(source, branch, bindings: bindings)

    assert {:ok, %{"$Answers" => [[^first, :first], [^second, :second], [^third, :third]]}, _} =
             result

    assert result == answer(source, branch, bindings: bindings, trace: [:domino])
  end

  example nested_field_requirements_preserve_siblings_and_share_code() do
    branch = install_protocol()

    assert %AL{result: {:atomic, _}} =
             AL.run(
               ~S"""
               assumption_probe >> selected_payload
               | Self Output |
               get Self selected Key,
               get Self Key Output.
               assumption_probe >> selected_children
               | Self Left Right |
               get Self left LeftChild,
               selected_payload LeftChild Left,
               get Self right RightChild,
               selected_payload RightChild Right.
               """,
               branch
             )

    first = %{
      class: :assumption_probe,
      left: %{class: :assumption_probe, selected: :payload, payload: :first},
      right: %{class: :assumption_probe, selected: :alternate, alternate: 7}
    }

    second = %{
      first
      | left: %{first.left | payload: :second},
        right: Map.put(%{first.right | alternate: 8}, :tag, :unused)
    }

    changed = %{second | right: %{class: :assumption_probe, selected: :payload, payload: 9}}
    arguments = [AL.Var.var("Left"), AL.Var.var("Right")]

    assert {:atomic, %Plan{assumptions: requirements}} =
             :mnesia.transaction(fn ->
               Plan.compile(Call.new(first, :selected_children, arguments), branch)
             end)

    assert requirements == [
             %{
               class: :assumption_probe,
               fields: %{
                 left: %{
                   class: :assumption_probe,
                   fields: %{selected: %{value: :payload}}
                 },
                 right: %{
                   class: :assumption_probe,
                   fields: %{selected: %{value: :alternate}}
                 }
               }
             },
             %{},
             %{}
           ]

    compiled = selected(first, :selected_children, branch, arguments)
    assert selected(second, :selected_children, branch, arguments) == compiled
    refute selected(changed, :selected_children, branch, arguments) == compiled

    for {receiver, left, right} <- [
          {first, :first, 7},
          {second, :second, 8},
          {changed, :second, 9}
        ],
        trace <- [[], [:domino]] do
      assert {:ok, %{"$Returned" => ^receiver, "$Left" => ^left, "$Right" => ^right}, %{}} =
               answer("selected_children Receiver Left Right, = Returned Receiver.", branch,
                 bindings: %{"Receiver" => receiver},
                 trace: trace
               )
    end

    missing = %{first | right: Map.delete(first.right, :selected)}
    refute Assumptions.accepts?(requirements, Call.new(missing, :selected_children, arguments))
  end

  example requirements_are_derived_from_bindings_and_constraints() do
    branch = install_protocol()

    assert %AL{result: {:atomic, _}} =
             AL.run(
               ~S"""
               assumption_probe >> selected_child
               | Self Output |
               get Self child Child,
               get Child selected Key,
               get Child Key Output.
               """,
               branch
             )

    child = AL.Var.var("Child")
    key = AL.Var.var("Key")
    alias_key = AL.Var.var("AliasKey")
    output = AL.Var.var("Output")

    receiver = %{
      class: :assumption_probe,
      child: %{class: :assumption_probe, selected: key, payload: 7}
    }

    store = AL.Var.unify(key, alias_key, %{}, branch)
    {store, _domain} = AL.Var.add_domain(store, AL.Var.deref(store, key), [:payload])
    call = Call.new(receiver, :selected_child, {:operands, {:constant, [output]}, {}, store})

    assert {:atomic, %Plan{assumptions: requirements, compiled: {_, _}}} =
             :mnesia.transaction(fn -> Plan.compile(call, branch) end)

    assert requirements == [
             %{
               class: :assumption_probe,
               fields: %{
                 child: %{
                   class: :assumption_probe,
                   fields: %{selected: %{value: :payload}}
                 }
               }
             },
             %{}
           ]

    assert Assumptions.accepts?(requirements, call)
    refute Assumptions.accepts?(requirements, %{call | store: %{}})
    assert AL.Var.var?(AL.Var.deref(store, key))
    broad_store = AL.Var.unify(key, alias_key, %{}, branch)

    {broad_store, _domain} =
      AL.Var.add_domain(broad_store, AL.Var.deref(broad_store, key), [:payload, :other])

    refute Assumptions.accepts?(requirements, %{call | store: broad_store})
    constrained_store = AL.Var.add_key(store, child, :selected, key, branch)

    constrained_call = %{
      call
      | arguments: {:cons, {:constant, %{child: child}}, {:constant, [output]}},
        store: constrained_store
    }

    field_requirements = [%{fields: %{child: %{fields: %{selected: %{value: :payload}}}}}]
    assert Assumptions.accepts?(field_requirements, constrained_call)
    refute Assumptions.accepts?(field_requirements, %{constrained_call | store: %{}})
    assert AL.Var.var?(AL.Var.deref(constrained_store, child))

    bound = %{
      class: :assumption_probe,
      child: %{class: :assumption_probe, selected: :payload, payload: 7}
    }

    assert Assumptions.accepts?(requirements, Call.new(bound, :selected_child, [output]))

    refute Assumptions.accepts?(
             requirements,
             Call.new(put_in(bound, [:child, :selected], :other), :selected_child, [output])
           )

    source = ~S"""
    = Child #{class => assumption_probe, selected => Key, payload => 7},
    in_domain Key [payload],
    selected_child #{class => assumption_probe, child => Child} Output.
    """

    result = answer(source, branch, [])
    assert {:ok, %{"$Output" => 7, "$Key" => :payload}, _} = result
    assert result == answer(source, branch, trace: [:domino])
  end

  example value_objects_share_code_and_return_complete_bindings() do
    branch = install_protocol()
    first = %{class: :assumption_probe, payload: :first, tag: :a}
    compiled = selected(first, :capture, branch)

    for receiver <- [
          first,
          %{class: :assumption_probe, payload: String.duplicate("x", 4096)},
          %{
            class: :assumption_probe,
            payload: List.duplicate(:value, 128),
            tag: :b,
            extra: :kept,
            another: :kept
          }
        ] do
      assert selected(receiver, :capture, branch) == compiled

      for trace <- [[], [:vm], [:domino]] do
        assert {:ok, %{"$Returned" => ^receiver, "$Value" => value}, constraints} =
                 answer("capture Receiver Returned Value.", branch,
                   bindings: %{"Receiver" => receiver},
                   trace: trace
                 )

        assert value == receiver.payload
        assert constraints == %{}
      end
    end
  end

  example backtracking_keeps_each_receivers_values() do
    branch = install_protocol()

    source = ~S"""
    findall [Returned, Value] Answers {
      member [
        #{class => assumption_probe, payload => 7, tag => a},
        #{class => assumption_probe, payload => 8, tag => b}
      ] Receiver,
      capture Receiver Returned Value
    }.
    """

    result = answer(source, branch, [])

    assert {:ok,
            %{
              "$Answers" => [
                [%{class: :assumption_probe, payload: 7, tag: :a}, 7],
                [%{class: :assumption_probe, payload: 8, tag: :b}, 8]
              ]
            }, %{}} = result

    assert result == answer(source, branch, trace: [:domino])
  end

  example aliases_and_constraints_survive_shared_plans() do
    branch = install_protocol()

    for source <- [
          ~S"in_domain X [7,8], capture #{class => assumption_probe, payload => [X,X]} Returned Value, = Value [7,Y].",
          ~S"in_domain X [7,8], capture #{class => assumption_probe, payload => X} Returned Value.",
          ~S"in_domain X [8,9], capture #{class => assumption_probe, payload => X} Returned 7.",
          ~S"in_domain X [7,8], assumption_echo [X,X . Tail] Returned, = Returned [7,Y,9].",
          ~S"in_domain X [8,9], assumption_head [X . Tail] 7.",
          ~S"assumption_head [] Output."
        ] do
      assert answer(source, branch, []) == answer(source, branch, trace: [:domino])
    end

    assert {:ok, %{"$X" => 7, "$Y" => 7, "$Tail" => [9], "$Returned" => [7, 7, 9]}, %{}} =
             answer("assumption_echo [X,X . Tail] Returned, = Returned [7,Y,9].", branch, [])

    assert {:ok, %{"$X" => x, "$Value" => x, "$Returned" => %{payload: x}}, constraints} =
             answer(
               ~S"in_domain X [7,8], capture #{class => assumption_probe, payload => X} Returned Value.",
               branch,
               []
             )

    refute constraints == %{}
  end

  example list_plans_ignore_length_and_open_tails() do
    branch = install_protocol()
    compiled = selected([:first], :assumption_head, branch)

    for receiver <- [[], List.duplicate(:value, 1000), [AL.Var.var("X") | AL.Var.var("Tail")]] do
      assert selected(receiver, :assumption_head, branch) == compiled
    end

    assert {:ok, %{"$Output" => :first, "$Tail" => tail}, %{}} =
             answer("assumption_head [first . Tail] Output.", branch, [])

    assert AL.Var.var?(tail)
  end

  example argument_dispatch_facts_share_plans() do
    branch = install_protocol()
    receiver = %{class: :assumption_probe}
    first = %{class: :assumption_probe, payload: :first}
    second = %{class: :assumption_other, alternate: :second}
    outputs = [AL.Var.var("A"), AL.Var.var("B")]
    open_arguments = [AL.Var.var("Left"), AL.Var.var("Right") | outputs]
    unspecialized = selected(receiver, :inspect_pair, branch, open_arguments)
    compiled = selected(receiver, :inspect_pair, branch, [first, second | outputs])
    refute compiled == unspecialized
    assert selected(receiver, :inspect_pair, branch, open_arguments) == unspecialized
    changed = %{first | payload: List.duplicate(:changed, 1000)}

    assert selected(receiver, :inspect_pair, branch, [changed, second | outputs]) == compiled
    refute selected(receiver, :inspect_pair, branch, [second, first | outputs]) == compiled

    source = ~S"""
    findall [A,B] Answers {
      member [[First,Second], [Second,First], [Changed,Second]] [Left,Right],
      inspect_pair Receiver Left Right A B
    }.
    """

    bindings = %{
      "Receiver" => receiver,
      "First" => first,
      "Second" => second,
      "Changed" => changed
    }

    result = answer(source, branch, bindings: bindings)

    assert {:ok, %{"$Answers" => [[:first, :second], [:second, :first], [payload, :second]]}, %{}} =
             result

    assert payload == changed.payload
    assert result == answer(source, branch, bindings: bindings, trace: [:domino])
  end

  example open_map_keys_keep_dispatch_dynamic() do
    branch = install_protocol()

    source = ~S"""
    findall Output Answers {
      member [
        #{class => assumption_probe, payload => first},
        #{class => assumption_probe, payload => wrong, alternate => second, Key => assumption_other}
      ] Receiver,
      retag Receiver Key Output
    }.
    """

    result = answer(source, branch, [])
    assert {:ok, %{"$Answers" => [:first, :second]}, %{}} = result
    assert result == answer(source, branch, trace: [:domino])
  end

  example sends_derive_requirements_from_the_live_arguments() do
    branch = install_protocol()

    assert %AL{result: {:atomic, _}} =
             AL.run(
               ~S"""
               assumption_probe >> forward
               | _Self Other Output |
               guarded_payload Other Output.
               assumption_probe >> guarded_payload
               | Self Output |
               cut,
               get Self payload Output.
               assumption_other >> guarded_payload
               | Self Output |
               cut,
               get Self alternate Output.
               """,
               branch
             )

    receiver = %{class: :assumption_probe}
    other = %{class: :assumption_probe, payload: :first}
    assumptions = Call.new(receiver, :forward, [other, AL.Var.var("Output")])

    assert {:atomic, %Plan{inlined: 0, compiled: nil}} =
             :mnesia.transaction(fn -> Plan.compile(assumptions, branch) end)

    source = ~S"""
    findall Output Answers {
      member [
        #{class => assumption_probe, payload => first},
        #{class => assumption_probe, payload => second, tag => changed},
        #{class => assumption_other, alternate => third}
      ] Other,
      forward Receiver Other Output
    }.
    """

    result = answer(source, branch, bindings: %{"Receiver" => receiver})
    assert {:ok, %{"$Answers" => [:first, :second, :third]}, %{}} = result
    assert result == answer(source, branch, bindings: %{"Receiver" => receiver}, trace: [:domino])

    assert %AL{result: {:atomic, _}} =
             AL.run(
               ~S"""
               assumption_probe >> guarded_payload
               | Self Output |
               cut,
               get Self replacement Output.
               """,
               branch
             )

    assert {:ok, %{"$Output" => :updated}, %{}} =
             answer("forward Receiver Other Output.", branch,
               bindings: %{
                 "Receiver" => receiver,
                 "Other" => Map.put(other, :replacement, :updated)
               }
             )
  end

  example recursive_sends_keep_outputs() do
    branch = install_protocol()

    source = ~S"""
    assumption_walk [
      #{class => assumption_probe, payload => [X,X]},
      #{class => assumption_probe, payload => second, tag => different},
      #{class => assumption_other, alternate => third}
    ] Result,
    = Result [[7,Y],second,third].
    """

    result = answer(source, branch, [])
    assert {:ok, %{"$Result" => [[7, 7], :second, :third], "$X" => 7, "$Y" => 7}, %{}} = result
    assert result == answer(source, branch, trace: [:domino])
    compiled = selected([], :assumption_walk, branch, [AL.Var.var("Output")])

    assert selected([:any | AL.Var.var("Tail")], :assumption_walk, branch, [AL.Var.var("Other")]) ==
             compiled
  end

  example method_edits_invalidate_branch_local_plans() do
    branch = install_protocol()
    receiver = %{class: :assumption_probe, payload: :original, replacement: :updated}
    selected(receiver, :capture, branch)
    fork = AL.Branch.fork(:tip, branch)

    try do
      assert %AL{result: {:atomic, _}} =
               AL.run(
                 ~S"""
                 assumption_probe >> payload
                 | Self Value |
                 get Self replacement Value.
                 """,
                 fork
               )

      for {target, expected} <- [{branch, :original}, {fork, :updated}] do
        assert {:ok, %{"$Value" => ^expected, "$Returned" => ^receiver}, %{}} =
                 answer("capture Receiver Returned Value.", target,
                   bindings: %{"Receiver" => receiver}
                 )
      end

      assert {:ok, %{"$Value" => :updated, "$Returned" => ^receiver}, %{}} =
               answer(
                 ~S"""
                 capture Receiver Before First.
                 assumption_probe >> payload
                 | Self Value |
                 get Self replacement Value.
                 capture Receiver Returned Value.
                 """,
                 branch,
                 bindings: %{"Receiver" => receiver}
               )
    after
      AL.Branch.discard(fork)
    end
  end

  example recursive_local_output_bindings() do
    branch = install_protocol()

    assert %AL{result: {:atomic, {%{"$O" => object}, _, _}}} =
             AL.run(
               ~S"""
               new object O.
               O >> r1
               | _S [] [] |.
               O >> r1
               | S [_H . T] [G . R] |
               = G 7,
               r1 S T R.
               O >> w1
               | S Q |
               r1 S [1, 2] C,
               = Q C.
               """,
               branch
             )

    for trace <- [[], [:vm], [:domino]] do
      assert {:ok, %{"$Q" => [7, 7]}, constraints} =
               answer("w1 O Q.", branch, bindings: %{"O" => object}, trace: trace)

      assert constraints == %{}
    end
  end

  example nested_recursive_outputs_keep_aliases_and_reverse_bindings() do
    branch = install_protocol()

    assert %AL{result: {:atomic, _}} =
             AL.run(
               ~S"""
               assumption_probe >> wrap_values
               | _Self [] [] |.
               assumption_probe >> wrap_values
               | Self [H . T] [#{value => G, alias => G} . R] |
               = G H,
               wrap_values Self T R.
               assumption_probe >> wrapped_values
               | Self Input Output |
               wrap_values Self Input Local,
               = Output Local.
               """,
               branch
             )

    for {source, expected} <- [
          {~S"wrapped_values #{class => assumption_probe} [7, 8] Output.",
           %{"$Output" => [%{value: 7, alias: 7}, %{value: 8, alias: 8}]}},
          {~S"wrapped_values #{class => assumption_probe} [X, X] Output, = X 9.",
           %{"$X" => 9, "$Output" => [%{value: 9, alias: 9}, %{value: 9, alias: 9}]}},
          {~S"wrapped_values #{class => assumption_probe} [X, Y] [#{value => 7, alias => 7}, #{value => 8, alias => 8}].",
           %{"$X" => 7, "$Y" => 8}},
          {~S"findall Output Outputs {member [7, 8] X, wrapped_values #{class => assumption_probe} [X] Output}.",
           %{"$Outputs" => [[%{value: 7, alias: 7}], [%{value: 8, alias: 8}]]}}
        ] do
      result = answer(source, branch, [])
      assert {:ok, ^expected, constraints} = result
      assert constraints == %{}
      assert result == answer(source, branch, trace: [:domino])
    end
  end
end
