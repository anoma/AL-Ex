defmodule Examples.ALJAMCompiler do
  use ExExample
  import ExUnit.Assertions

  defp evaluate(source, options \\ []),
    do: AL.run(source, %AL.Branch{id: Examples.Support.branch()}, options)

  example transaction_context_survives_calls_mutations_and_collections() do
    source = ~S"""
    @jam_context_probe #{super => object, ivars => [#{name => touched}]}.

    jam_context_probe >> identity
    | _Self Tx Object |
    vm_current_tx Tx,
    vm_transaction_object Object.

    jam_context_probe >> exercise
    | Self Tx Object Rows |
    identity Self Tx Object,
    set_slot Self touched true,
    identity Self Tx Object,
    call [T, O] {vm_current_tx T, vm_transaction_object O} [Tx, Object],
    findall [N, ChildTx, ChildObject] Rows {
      member [a, b] N,
      identity Self ChildTx ChildObject
    },
    not {identity Self impossible _},
    identity Self Tx Object.

    vm_set_class jam_context_instance jam_context_probe.
    exercise jam_context_instance Tx Object Rows.
    """

    {:atomic, {bindings, _, state}} = evaluate(source)
    assert bindings["$Tx"] == state.tx_id
    assert bindings["$Object"] == state.transaction_object
    tx = state.tx_id
    assert [[:a, ^tx, first], [:b, ^tx, second]] = bindings["$Rows"]
    assert first == nil and second == nil
  end

  example open_receiver_continuations_run_once() do
    source = ~S"""
    @jam_open_counter #{super => object, ivars => [#{name => count}]}.

    jam_open_counter >> walk
    | _Self [] |.

    jam_open_counter >> walk
    | Self [_ . Rest] |
    class Receiver map,
    get Receiver token Value,
    = Receiver #{token => 7},
    == Value 7,
    get Self count Count,
    = Next (+ Count 1),
    set_slot Self count Next,
    walk Self Rest.

    vm_set_class jam_open_counter_instance jam_open_counter.
    set_slot jam_open_counter_instance count 0.
    walk jam_open_counter_instance [a, b, c, d].
    get jam_open_counter_instance count Count.
    """

    {:atomic, {bindings, _, _}} = evaluate(source)
    assert bindings["$Count"] == 4
  end

  example open_sends_preserve_overrides_late_receivers_and_map_suspension() do
    source = ~S"""
    @jam_open_base #{super => object, ivars => [#{name => count}]}.
    @jam_open_child #{super => jam_open_base}.
    @jam_open_probe #{super => object}.

    jam_open_child >> get
    | Self count Value |
    slot Self count Stored,
    = Value (+ Stored 1).

    jam_open_probe >> read
    | _Self Receiver Value |
    get Receiver count Value.

    jam_open_probe >> deferred_map
    | _Self Value |
    map_get Map Key Value,
    = Key token,
    = Map #{token => 3}.

    vm_set_class jam_open_instance jam_open_child.
    vm_set_class jam_open_reader jam_open_probe.
    set_slot jam_open_instance count 7.
    findall Value Values {
      read jam_open_reader Receiver Value,
      = Receiver jam_open_instance
    }.
    class Known jam_open_child.
    read jam_open_reader Known Selected.
    = Known jam_open_instance.
    read jam_open_reader Map MapValue.
    = Map #{count => 9}.
    deferred_map jam_open_reader Deferred.
    """

    expected = %{
      "$Self" => {:"$var", "Self"},
      "$_Self" => {:"$var", "_Self"},
      "$Value" => {:"$var", "Value"},
      "$Key" => {:"$var", "Key"},
      "$Values" => ~c"\b",
      "$Receiver" => {:"$var", "Receiver"},
      "$Map" => %{count: 9},
      "$Selected" => 8,
      "$MapValue" => 9,
      "$Deferred" => 3,
      "$Known" => :jam_open_instance,
      "$Stored" => {:"$var", "Stored"}
    }

    {:atomic, {actual, _, _}} = evaluate(source)
    assert actual == expected
    assert actual["$Values"] == [8]
    assert actual["$Selected"] == 8
    assert actual["$MapValue"] == 9
    assert actual["$Deferred"] == 3
  end

  example compiled_gensym_preserves_generation_constraints_and_allocation() do
    source = ~S"""
    @jam_gensym_probe #{super => object, ivars => [#{name => value}]}.

    jam_gensym_probe >> symbols
    | _Self Symbols |
    findall Symbol Symbols {member [a, b, c] _, gensym Symbol},
    not {gensym fixed},
    isa Number number,
    not {gensym Number}.

    jam_gensym_probe >> allocate_pair
    | _Self Anonymous Named |
    new jam_gensym_probe #{value => 7} Anonymous,
    new jam_gensym_probe #{name => jam_gensym_named, value => 9} Named.

    vm_set_class jam_gensym_instance jam_gensym_probe.
    symbols jam_gensym_instance Symbols.
    allocate_pair jam_gensym_instance Anonymous Named.
    get Anonymous value AnonymousValue.
    get Named value NamedValue.
    """

    {:atomic, {bindings, _, _}} = evaluate(source)
    symbols = bindings["$Symbols"]
    assert length(symbols) == 3
    assert length(Enum.uniq(symbols)) == 3

    assert Enum.all?(
             symbols,
             &(is_atom(&1) and Regex.match?(~r/^[0-9a-f]{32}$/, Atom.to_string(&1)))
           )

    assert bindings["$Named"] == :jam_gensym_named
    assert bindings["$AnonymousValue"] == 7
    assert bindings["$NamedValue"] == 9
  end

  example direct_applications_preserve_alternatives_and_method_edits() do
    source = ~S"""
    @jam_direct_probe #{super => object}.

    jam_direct_probe >> choose
    | _Self red |.

    jam_direct_probe >> choose
    | _Self blue |.

    jam_direct_probe >> apply
    | _Self Method Receiver Value |
    vm_oapply Method [Receiver, Value].

    jam_direct_probe >> extend
    | _Self |
    defmethod jam_direct_probe choose [_Receiver, green] {}.

    vm_set_class jam_direct_instance jam_direct_probe.
    method jam_direct_probe choose Method.
    findall Value Before {apply jam_direct_instance Method jam_direct_instance Value}.
    extend jam_direct_instance.
    findall Value After {apply jam_direct_instance Method jam_direct_instance Value}.
    dif Selected red.
    apply jam_direct_instance Method jam_direct_instance Selected.
    not {apply jam_direct_instance Method jam_direct_instance missing}.
    """

    expected = %{
      "$Method" => :"#479",
      "$_Self" => {:"$var", "_Self"},
      "$Value" => {:"$var", "Value"},
      "$After" => [:red, :blue, :green],
      "$Receiver" => {:"$var", "Receiver"},
      "$Selected" => :blue,
      "$_Receiver" => {:"$var", "_Receiver"},
      "$Before" => [:red, :blue]
    }

    {:atomic, {actual, _, _}} = evaluate(source)
    assert Map.drop(actual, ["$Method"]) == Map.drop(expected, ["$Method"])
    assert actual["$Before"] == [:red, :blue]
    assert actual["$After"] == [:red, :blue, :green]
    assert actual["$Selected"] == :blue
  end

  example direct_applications_execute_open_list_and_map_heads() do
    source = ~S"""
    @jam_head_machine_probe #{super => object}.

    jam_head_machine_probe >> shape
    | _Self [Head . Tail] #{item => Head, rest => Tail} |.

    method jam_head_machine_probe shape Method.
    vm_oapply Method [jam_head_machine_probe, [a, b], Result].
    vm_oapply Method [jam_head_machine_probe, Constructed, #{item => c, rest => []}].
    """

    {:atomic, {bindings, _, _}} = evaluate(source)
    assert bindings["$Result"] == %{item: :a, rest: [:b]}
    assert bindings["$Constructed"] == [:c]
  end

  example direct_application_choices_survive_mutation_handoffs() do
    source = ~S"""
    @jam_choice_machine_probe #{super => object, ivars => [#{name => count}]}.

    jam_choice_machine_probe >> choose
    | Self red |
    set_slot Self count 1.

    jam_choice_machine_probe >> choose
    | Self blue |
    set_slot Self count 2.

    vm_set_class jam_choice_machine_instance jam_choice_machine_probe.
    method jam_choice_machine_probe choose Method.
    findall Value Results {vm_oapply Method [jam_choice_machine_instance, Value]}.
    """

    {:atomic, {bindings, _, _}} = evaluate(source)
    assert bindings["$Results"] == [:red, :blue]
  end

  example native_calls_preserve_answers_suspensions_cuts_and_next_provider() do
    branch = %AL.Branch{id: Examples.Support.branch()}

    {:atomic, _} =
      evaluate(~S"""
      @jam_native_runner #{super => object}.
      @jam_native_parent #{super => value}.
      @jam_native_child #{super => jam_native_parent}.

      jam_native_runner >> choose
      | _Self D |
      jam_native_divisors 6 D.

      jam_native_runner >> first
      | Self D |
      choose Self D,
      cut.

      jam_native_runner >> gcd
      | _Self Result |
      jam_native_gcd 12 8 Result.

      jam_native_child >> describe
      | Self Result |
      call_next_method Self Result.

      vm_set_class jam_native_runner_instance jam_native_runner.
      """)

    {:ok, raw} =
      AL.Native.register(:number, :jam_native_divisors, Examples.ALNative.Divisors, :divisors, 3,
        style: :raw,
        branch: branch
      )

    {:ok, value} = AL.Native.register(:number, :jam_native_gcd, Integer, :gcd, 2, branch: branch)

    {:ok, parent} =
      AL.Native.register(:jam_native_parent, :describe, Kernel, :inspect, 1, branch: branch)

    try do
      query = ~S"""
      findall D All {choose jam_native_runner_instance D}.
      findall D Filtered {freeze D {dif D 2}, choose jam_native_runner_instance D}.
      findall D First {first jam_native_runner_instance D}.
      gcd jam_native_runner_instance Gcd.
      describe #{class => jam_native_child} Description.
      """

      expected = %{
        "$First" => [1],
        "$All" => [1, 2, 3, 6],
        "$Filtered" => [1, 3, 6],
        "$Gcd" => 4,
        "$Description" => "%{class: :jam_native_child}"
      }

      {:atomic, {actual, _, _}} = evaluate(query)
      assert actual == expected
      assert actual["$All"] == [1, 2, 3, 6]
      assert actual["$Filtered"] == [1, 3, 6]
      assert actual["$First"] == [1]
      assert actual["$Gcd"] == 4
      assert actual["$Description"] == inspect(%{class: :jam_native_child})

      AL.Native.Registry.delete(value)
      {:aborted, failure} = evaluate("gcd jam_native_runner_instance Result.")
      assert {:native_missing, ^value, {Integer, :gcd, 2}} = failure.reason
    after
      for method <- [raw, value, parent], do: AL.Native.retract(method, branch: branch)
    end
  end

  example direct_native_applications_preserve_nondeterministic_answers() do
    branch = %AL.Branch{id: Examples.Support.branch()}

    {:ok, method} =
      AL.Native.register(:number, :jam_direct_divisors, Examples.ALNative.Divisors, :divisors, 3,
        style: :raw,
        branch: branch
      )

    try do
      source = ~S"""
      @jam_direct_native_probe #{super => object}.

      jam_direct_native_probe >> collect
      | _Self Method Results |
      findall Value Results {vm_oapply Method [6, Value]}.

      vm_set_class jam_direct_native_instance jam_direct_native_probe.
      method number jam_direct_divisors Method.
      collect jam_direct_native_instance Method Results.
      """

      expected = %{
        "$_Self" => {:"$var", "_Self"},
        "$Value" => {:"$var", "Value"},
        "$Results" => [1, 2, 3, 6]
      }

      {:atomic, {actual, _, _}} = evaluate(source)
      assert Map.delete(actual, "$Method") == expected
      assert actual["$Method"] == method
      assert actual["$Results"] == [1, 2, 3, 6]
    after
      AL.Native.retract(method, branch: branch)
    end
  end

  example durable_slot_instructions_preserve_storage_choices_and_open_constraints() do
    source = ~S"""
    @jam_slot_probe
    #{super => object, ivars => [
      #{name => color, domain => [red, blue]},
      #{name => count, storage => soa, type => number}
    ]}.

    jam_slot_probe >> read_both
    | Self Color Count |
    get Self color Color,
    get Self count Count.

    jam_slot_probe >> entries
    | Self Entries |
    findall [Key, Value] Entries {slot Self Key Value aos}.

    jam_slot_probe >> constrain
    | _Self Object Color |
    isa Object jam_slot_probe,
    slot Object color Color.

    vm_set_class jam_slot_instance jam_slot_probe.
    set_slot jam_slot_instance color red.
    set_slot jam_slot_instance count 7.
    read_both jam_slot_instance Color Count.
    entries jam_slot_instance Entries.
    constrain jam_slot_instance Open Choice.
    not {= Choice green}.
    = Open jam_slot_instance.
    findall N Counts {slot jam_slot_instance count N soa}.
    """

    expected = %{
      "$Self" => {:"$var", "Self"},
      "$_Self" => {:"$var", "_Self"},
      "$Value" => {:"$var", "Value"},
      "$Key" => {:"$var", "Key"},
      "$Entries" => [[:color, :red]],
      "$Object" => {:"$var", "Object"},
      "$Color" => :red,
      "$Open" => :jam_slot_instance,
      "$Count" => 7,
      "$Choice" => :red,
      "$Counts" => ~c"\a"
    }

    {:atomic, {actual, _, _}} = evaluate(source)
    assert actual == expected
    assert actual["$Color"] == :red
    assert actual["$Count"] == 7
    assert actual["$Choice"] == :red
    assert actual["$Counts"] == [7]
    assert [:color, :red] in actual["$Entries"]
    refute Enum.any?(actual["$Entries"], fn [key, _] -> key == :count end)
  end

  example head_references_preserve_aliases_constraints_and_backtracking() do
    source = ~S"""
    @jam_reference_probe #{super => object}.

    jam_reference_probe >> relay
    | Self Input Output |
    same Self Input Output.

    jam_reference_probe >> same
    | _Self Value Value |.

    vm_set_class jam_reference_instance jam_reference_probe.
    = Literal [a, b, c].
    relay jam_reference_instance Literal Copied.
    = Bound item.
    = Nested [Bound, #{payload => Bound}].
    relay jam_reference_instance Nested Resolved.
    = Open [Head . Tail].
    relay jam_reference_instance Open Alias.
    dif Head forbidden.
    = Alias [allowed, end].
    findall Answer Answers {
      member [first, second] Item,
      = Input [Item],
      relay jam_reference_instance Input Answer
    }.
    not {relay jam_reference_instance Loop [Loop]}.
    """

    expected = %{
      "$Self" => {:"$var", "Self"},
      "$Head" => :allowed,
      "$_Self" => {:"$var", "_Self"},
      "$Value" => {:"$var", "Value"},
      "$Output" => {:"$var", "Output"},
      "$Input" => {:"$var", "Input"},
      "$Literal" => [:a, :b, :c],
      "$Tail" => [:end],
      "$Open" => [:allowed, :end],
      "$Answers" => [[:first], [:second]],
      "$Nested" => [:item, %{payload: :item}],
      "$Bound" => :item,
      "$Alias" => [:allowed, :end],
      "$Copied" => [:a, :b, :c],
      "$Resolved" => [:item, %{payload: :item}]
    }

    expected_constraints = %{}
    {:atomic, {actual, actual_constraints, _}} = evaluate(source)
    assert actual == expected
    assert actual_constraints == expected_constraints
    assert actual["$Copied"] == [:a, :b, :c]
    assert actual["$Resolved"] == [:item, %{payload: :item}]
    assert actual["$Head"] == :allowed
    assert actual["$Tail"] == [:end]
    assert actual["$Answers"] == [[:first], [:second]]
  end

  example repeated_cache_invalidation_preserves_reclassification_and_rollback() do
    {:atomic, _} =
      evaluate(~S"""
      @jam_cache_first #{super => object}.
      @jam_cache_second #{super => object}.

      jam_cache_first >> cached_value
      | _Self first |.

      jam_cache_second >> cached_value
      | _Self second |.

      vm_set_class jam_cache_instance jam_cache_first.
      cached_value jam_cache_instance first.
      """)

    {:atomic, {bindings, _, _}} =
      evaluate(~S"""
      vm_retract_class jam_cache_instance jam_cache_first.
      vm_set_class jam_cache_instance jam_cache_second.
      cached_value jam_cache_instance A.
      vm_retract_class jam_cache_instance jam_cache_second.
      vm_set_class jam_cache_instance jam_cache_first.
      cached_value jam_cache_instance B.
      vm_retract_class jam_cache_instance jam_cache_first.
      vm_set_class jam_cache_instance jam_cache_second.
      cached_value jam_cache_instance C.
      """)

    assert [bindings["$A"], bindings["$B"], bindings["$C"]] == [:second, :first, :second]

    assert {:aborted, _} =
             evaluate(~S"""
             vm_retract_class jam_cache_instance jam_cache_second.
             vm_set_class jam_cache_instance jam_cache_first.
             cached_value jam_cache_instance first.
             fail.
             """)

    assert {:atomic, _} = evaluate("cached_value jam_cache_instance second.")
  end

  example mutation_instructions_preserve_search_effects_and_transaction_rollback() do
    source = ~S"""
    @jam_mutation_probe
    #{super => object, ivars => [#{name => count}]}.

    jam_mutation_probe >> exercise
    | Self Values |
    {vm_set_slot Self count 1, fail} ; pass,
    get Self count 1,
    findall N Values {member [2, 3] N, vm_set_slot Self count N},
    get Self count 3,
    vm_retract_slot Self count,
    not {get Self count _},
    vm_set_slot Self count 4.

    jam_mutation_probe >> abort_write
    | Self |
    vm_set_slot Self count 999,
    fail.

    vm_set_class jam_mutation_target jam_mutation_probe.
    """

    branch = AL.Branch.fork(:tip, %AL.Branch{id: Examples.Support.branch()})

    try do
      {:atomic, _} = AL.run(source, branch)

      {:atomic, {bindings, _, state}} =
        AL.run("exercise jam_mutation_target Values.", branch)

      assert bindings["$Values"] == [2, 3]
      assert {:aborted, _} = AL.run("abort_write jam_mutation_target.", branch)

      {:atomic, {afterwards, _, _}} =
        AL.run("get jam_mutation_target count Value.", branch)

      assert afterwards["$Value"] == 4

      {:atomic, operations} =
        :mnesia.transaction(fn ->
          AL.Command.commands_for_transaction(state.tx_id, branch)
          |> Enum.sort_by(&elem(&1, 1))
          |> Enum.map(&elem(&1, 3))
          |> Enum.filter(fn
            {:set_slot, {:jam_mutation_target, :count, _, _}} -> true
            {:retract_slot, {:jam_mutation_target, :count, _}} -> true
            _ -> false
          end)
        end)

      assert length(operations) == 5

      assert operations == [
               set_slot: {:jam_mutation_target, :count, 1, :aos},
               set_slot: {:jam_mutation_target, :count, 2, :aos},
               set_slot: {:jam_mutation_target, :count, 3, :aos},
               retract_slot: {:jam_mutation_target, :count, :aos},
               set_slot: {:jam_mutation_target, :count, 4, :aos}
             ]
    after
      AL.Branch.discard(branch)
    end
  end

  example source_and_history_reads_preserve_answers_and_time_constraints() do
    source = ~S"""
    @jam_history_reader
    #{super => object, ivars => [#{name => count}]}.

    jam_history_reader >> inspect
    | Self Tx Result |
    vm_transaction_source Tx Text Origin,
    findall Found Matches {vm_transaction_source Found Text Origin},
    member Matches Tx,
    method jam_history_reader inspect Method,
    findall [Seq, Clause, Provenance] Clauses {vm_method_source Method Seq Clause Provenance},
    vm_slot_at Self count 1 First,
    label First,
    = Boundary (+ First 1),
    vm_slot_at Self count AtBoundary Boundary,
    not {vm_slot_at Self count 1 Late, >= Late Boundary},
    not {vm_slot_at Self missing _ _},
    not {vm_transaction_source -1 _ _},
    findall Value Values {vm_slot_at Self count Value _},
    = Result [Text, Clauses, AtBoundary, Values].

    new jam_history_reader Obj.
    set_slot Obj count 1.
    set_slot Obj count 2.
    """

    {:atomic, {setup, _, state}} = evaluate(source)

    program = [
      %AL.Goal.Send{
        object: setup["$Obj"],
        method: :inspect,
        args: [state.tx_id, {:"$var", "Result"}]
      }
    ]

    {:atomic, {actual, _, _}} = AL.eval(program, nil, %AL.Branch{id: Examples.Support.branch()})

    assert actual == %{
             "$Result" => [
               "@jam_history_reader\n\#{super => object, ivars => [\#{name => count}]}.\n\njam_history_reader >> inspect\n| Self Tx Result |\nvm_transaction_source Tx Text Origin,\nfindall Found Matches {vm_transaction_source Found Text Origin},\nmember Matches Tx,\nmethod jam_history_reader inspect Method,\nfindall [Seq, Clause, Provenance] Clauses {vm_method_source Method Seq Clause Provenance},\nvm_slot_at Self count 1 First,\nlabel First,\n= Boundary (+ First 1),\nvm_slot_at Self count AtBoundary Boundary,\nnot {vm_slot_at Self count 1 Late, >= Late Boundary},\nnot {vm_slot_at Self missing _ _},\nnot {vm_transaction_source -1 _ _},\nfindall Value Values {vm_slot_at Self count Value _},\n= Result [Text, Clauses, AtBoundary, Values].\n\nnew jam_history_reader Obj.\nset_slot Obj count 1.\nset_slot Obj count 2.\n",
               [
                 [
                   0,
                   "jam_history_reader >> inspect\n| Self Tx Result |\nvm_transaction_source Tx Text Origin,\nfindall Found Matches {vm_transaction_source Found Text Origin},\nmember Matches Tx,\nmethod jam_history_reader inspect Method,\nfindall [Seq, Clause, Provenance] Clauses {vm_method_source Method Seq Clause Provenance},\nvm_slot_at Self count 1 First,\nlabel First,\n= Boundary (+ First 1),\nvm_slot_at Self count AtBoundary Boundary,\nnot {vm_slot_at Self count 1 Late, >= Late Boundary},\nnot {vm_slot_at Self missing _ _},\nnot {vm_transaction_source -1 _ _},\nfindall Value Values {vm_slot_at Self count Value _},\n= Result [Text, Clauses, AtBoundary, Values]",
                   :retained
                 ]
               ],
               2,
               [1, 2]
             ]
           }

    [text, clauses, boundary, values] = actual["$Result"]
    assert text == source
    assert length(clauses) == 1
    assert boundary == 2
    assert Enum.sort(values) == [1, 2]
  end

  example branch_read_instructions_preserve_branch_identity_and_open_queries() do
    {:atomic, _} =
      evaluate(~S"""
      @jam_branch_reader #{super => value}.

      jam_branch_reader >> inspect
      | _Self Result |
      vm_current_branch Here,
      vm_branch_meta Here system_time Tick,
      >= Tick 0,
      findall Key Keys {vm_branch_meta Here Key _},
      findall Parent Parents {vm_branch Parent Here},
      findall Child Children {vm_branch Here Child},
      findall Branch Known {vm_branch_meta Branch system_time _},
      member Known Here,
      not {vm_branch_meta jam_missing_branch system_time _},
      = Result [Here, Keys, Parents, Children].
      """)

    parent = AL.Branch.fork(:tip, %AL.Branch{id: Examples.Support.branch()})
    child = AL.Branch.fork(:tip, parent)

    try do
      for branch <- [parent, child] do
        source = "inspect \#{class => jam_branch_reader} Result."

        {:atomic, {actual, _, _}} = AL.run(source, branch)
        [id, keys, parents, children] = actual["$Result"]
        assert id == branch.id
        assert :system_time in keys
        assert :fork_point in keys
        if branch == child, do: assert(parent.id in parents)
        if branch == parent, do: assert(child.id in children)
      end
    after
      AL.Branch.discard(child)
      AL.Branch.discard(parent)
    end
  end

  example all_dif_rejects_repeated_live_variables_before_and_after_aliasing() do
    source = ~S"""
    @jam_all_dif_alias #{super => value}.

    jam_all_dif_alias >> exercise
    | _Self Result |
    not {all_dif [Open, Open]},
    not {all_dif [Unknown, Repeated, Repeated]},
    not {all_dif [UnknownGround, 1, 1]},
    not {in_domain Finite [1, 2], all_dif [Finite, Finite]},
    not {= Left Right, all_dif [Left, Right]},
    not {all_dif [Before, After], = Before After},
    findall [X, Y] Answers {
      in_domain X [1, 2],
      in_domain Y [1, 2],
      all_dif [X, Y],
      {= X Y} ; {label X, label Y}
    },
    = Result Answers.

    exercise #{class => jam_all_dif_alias} Result.
    """

    expected = %{
      "$_Self" => {:"$var", "_Self"},
      "$Left" => {:"$var", "Left"},
      "$Right" => {:"$var", "Right"},
      "$X" => {:"$var", "X"},
      "$Result" => [[1, 2], [2, 1]],
      "$Y" => {:"$var", "Y"},
      "$After" => {:"$var", "After"},
      "$Open" => {:"$var", "Open"},
      "$Answers" => {:"$var", "Answers"},
      "$Repeated" => {:"$var", "Repeated"},
      "$Before" => {:"$var", "Before"},
      "$Unknown" => {:"$var", "Unknown"},
      "$UnknownGround" => {:"$var", "UnknownGround"},
      "$Finite" => {:"$var", "Finite"}
    }

    {:atomic, {actual, _, _}} = evaluate(source)
    assert actual == expected
    assert Enum.sort(actual["$Result"]) == [[1, 2], [2, 1]]
  end

  example native_domain_and_all_dif_preserve_propagation_and_backtracking() do
    source = ~S"""
    @jam_constraint_probe #{super => value}.

    jam_constraint_probe >> exercise
    | _Self Result |
    in_domain X [1, 2],
    in_domain Y [1, 2],
    in_domain Z [1, 2, 3],
    freeze Z {= Woken Z},
    all_dif [X, Y, Z],
    findall [X, Y, Z] Choices {label X, label Y, label Z},
    in_domain Narrow [red, blue],
    = Alias Narrow,
    freeze Alias {= Chosen Alias},
    in_domain Narrow [blue, green],
    not {in_domain Impossible [1], in_domain Impossible [2]},
    not {all_dif [X, X]},
    not {all_dif [1, 1]},
    not {all_dif invalid},
    = Result [Z, Woken, Choices, Chosen].

    exercise #{class => jam_constraint_probe} Result.
    """

    expected = %{
      "$_Self" => {:"$var", "_Self"},
      "$X" => {:"$var", "X"},
      "$Result" => [3, 3, [[1, 2, 3], [2, 1, 3]], :blue],
      "$Y" => {:"$var", "Y"},
      "$Z" => {:"$var", "Z"},
      "$Alias" => {:"$var", "Alias"},
      "$Woken" => {:"$var", "Woken"},
      "$Choices" => {:"$var", "Choices"},
      "$Chosen" => {:"$var", "Chosen"},
      "$Narrow" => {:"$var", "Narrow"},
      "$Impossible" => {:"$var", "Impossible"}
    }

    {:atomic, {actual, _, _}} = evaluate(source)
    assert actual == expected
    assert actual["$Result"] == [3, 3, [[1, 2, 3], [2, 1, 3]], :blue]
  end

  example class_labeling_keeps_witness_alternatives_and_suspensions() do
    source = ~S"""
    @jam_label_root #{super => object}.
    @jam_label_durable #{super => jam_label_root}.
    @jam_label_value #{super => [jam_label_root, value]}.
    @jam_label_runner #{super => object}.

    jam_label_value >> init
    | _Self _Args New |
    member [1, 2] N,
    = New #{class => jam_label_value, number => N}.

    jam_label_runner >> pick
    | _Self Object |
    isa Object jam_label_root,
    label Object.

    jam_label_runner >> first
    | Self Object |
    pick Self Object,
    cut.

    jam_label_runner >> delayed
    | Self Object |
    freeze Object {dif Object jam_label_one},
    pick Self Object.

    vm_set_class jam_label_one jam_label_durable.
    vm_set_class jam_label_two jam_label_durable.
    vm_set_class jam_label_runner_instance jam_label_runner.
    """

    {:atomic, _} = evaluate(source)

    query = ~S"""
    findall X All {pick jam_label_runner_instance X}.
    findall X First {first jam_label_runner_instance X}.
    findall X Filtered {delayed jam_label_runner_instance X}.
    """

    witnesses = [
      :jam_label_one,
      :jam_label_two,
      %{number: 1, class: :jam_label_value},
      %{number: 2, class: :jam_label_value}
    ]

    {:atomic, {actual, _, _}} = evaluate(query)
    assert Enum.sort(actual["$All"]) == Enum.sort(witnesses)
    assert length(actual["$All"]) == 4
    assert actual["$First"] == Enum.take(actual["$All"], 1)
    assert actual["$Filtered"] == Enum.reject(actual["$All"], &(&1 == :jam_label_one))
  end

  example native_label_preserves_domains_bounds_aliases_and_suspensions() do
    source = ~S"""
    @jam_label_probe #{super => value}.

    jam_label_probe >> pick
    | _Self Value |
    label Value.

    jam_label_probe >> pair
    | _Self X Y |
    label X,
    label Y.

    jam_label_probe >> delayed
    | _Self X |
    freeze X {dif X 2},
    label X.

    in_domain X [1, 2].
    in_domain Y [1, 2].
    dif X Y.
    = Alias X.
    findall [X, Y] Pairs {pair #{class => jam_label_probe} Alias Y}.
    findall N Numbers {>= N 1, <= N 3, pick #{class => jam_label_probe} N}.
    in_domain Delayed [1, 2, 3].
    findall Delayed Woken {delayed #{class => jam_label_probe} Delayed}.
    pick #{class => jam_label_probe} ready.
    """

    expected = %{
      "$_Self" => {:"$var", "_Self"},
      "$Value" => {:"$var", "Value"},
      "$Pairs" => [[1, 2], [2, 1]],
      "$X" => {:"$var", "Alias"},
      "$Y" => {:"$var", "Y"},
      "$Numbers" => [1, 2, 3],
      "$Alias" => {:"$var", "Alias"},
      "$Delayed" => {:"$var", "Delayed"},
      "$Woken" => [1, 3]
    }

    {:atomic, {actual, _, _}} = evaluate(source)
    assert actual == expected
    assert Enum.sort(actual["$Pairs"]) == [[1, 2], [2, 1]]
    assert actual["$Numbers"] == [1, 2, 3]
    assert Enum.sort(actual["$Woken"]) == [1, 3]
  end

  example forall_templates_keep_choicepoints_and_suspensions_per_solution() do
    source = ~S"""
    @jam_forall_template #{super => value}.

    jam_forall_template >> choices
    | _Self |
    forall {member [1, 2] Number} {
      member [red, blue] Color,
      freeze Gate {dif Color green, = Copy Number},
      = Gate ready,
      = Copy Number
    }.

    jam_forall_template >> exercise
    | Self Result |
    findall yes Choices {choices Self},
    forall {member [left, right] Key} {
      = Map #{Key => Key},
      get Map Key Value,
      = Value Key
    },
    = Result Choices.

    exercise #{class => jam_forall_template} Result.
    """

    expected = %{
      "$Self" => {:"$var", "Self"},
      "$_Self" => {:"$var", "_Self"},
      "$Value" => {:"$var", "Value"},
      "$Key" => {:"$var", "Key"},
      "$Result" => [:yes, :yes, :yes, :yes],
      "$Map" => {:"$var", "Map"},
      "$Number" => {:"$var", "Number"},
      "$Color" => {:"$var", "Color"},
      "$Choices" => {:"$var", "Choices"},
      "$Gate" => {:"$var", "Gate"},
      "$Copy" => {:"$var", "Copy"}
    }

    {:atomic, {actual, _, _}} = evaluate(source)
    assert actual == expected
    assert actual["$Result"] == [:yes, :yes, :yes, :yes]
  end

  example native_forall_preserves_shared_elements_body_choices_and_empty_search() do
    source = ~S"""
    @jam_forall_probe #{super => value}.

    jam_forall_probe >> fill
    | _Self Values |
    forall {member Values Item} {= Item 7}.

    jam_forall_probe >> bind_shared
    | _Self Value |
    forall {pass} {= Value 9}.

    jam_forall_probe >> choose
    | _Self |
    forall {member [1, 2] N} {member [N, N] N}.

    jam_forall_probe >> exercise
    | Self Result |
    = Values [A, B],
    fill Self Values,
    bind_shared Self Shared,
    ground Shared,
    = Shared 9,
    forall {fail} {fail},
    forall {member [1, 2, 3] N} {= Double (* N 2), <= Double 6},
    forall {in_domain N [1, 2], member [1, 2] N} {in_domain N [1, 2]},
    forall {member [1, 2] N} {forall {member [N] M} {= M N}},
    not {forall {member [1, 2, 3] N} {< N 3}},
    findall yes Choices {choose Self},
    = Result [Values, A, B, Choices].

    exercise #{class => jam_forall_probe} Result.
    """

    expected = %{
      "$Self" => {:"$var", "Self"},
      "$_Self" => {:"$var", "_Self"},
      "$Value" => {:"$var", "Value"},
      "$M" => {:"$var", "M"},
      "$Values" => {:"$var", "Values"},
      "$N" => {:"$var", "N"},
      "$Result" => [~c"\a\a", 7, 7, [:yes, :yes, :yes, :yes]],
      "$Item" => {:"$var", "Item"},
      "$A" => {:"$var", "A"},
      "$B" => {:"$var", "B"},
      "$Shared" => {:"$var", "Shared"},
      "$Choices" => {:"$var", "Choices"},
      "$Double" => {:"$var", "Double"}
    }

    {:atomic, {actual, _, _}} = evaluate(source)
    assert actual == expected
    assert actual["$Result"] == [[7, 7], 7, 7, [:yes, :yes, :yes, :yes]]
  end

  example native_forall_runs_durable_updates_in_solution_order() do
    source = ~S"""
    @jam_forall_log #{super => object, ivars => [#{name => items}]}.
    @jam_forall_effects #{super => value}.

    jam_forall_effects >> exercise
    | _Self Result |
    new jam_forall_log #{items => []} Log,
    forall {member [1, 2, 3] Item} {
      get Log items Before,
      concat Before [Item] After,
      set_slot Log items After
    },
    get Log items Result.

    exercise #{class => jam_forall_effects} Result.
    """

    expected = %{
      "$_Self" => {:"$var", "_Self"},
      "$Result" => [1, 2, 3],
      "$After" => {:"$var", "After"},
      "$Item" => {:"$var", "Item"},
      "$Log" => {:"$var", "Log"},
      "$Before" => {:"$var", "Before"}
    }

    {:atomic, {actual, _, _}} = evaluate(source)
    assert actual == expected
    assert actual["$Result"] == [1, 2, 3]
  end

  example native_isa_preserves_open_modes_enumeration_and_domain_narrowing() do
    source = ~S"""
    @jam_isa_probe #{super => value}.
    @jam_isa_parent #{super => value}.
    @jam_isa_child #{super => jam_isa_parent}.

    jam_isa_probe >> check
    | _Self Object Class |
    isa Object Class.

    jam_isa_probe >> exercise
    | Self Result |
    check Self Open number,
    = Open Alias,
    = Alias 7,
    check Self Linked LinkedClass,
    = LinkedClass number,
    = Linked 8,
    findall Class Classes {check Self #{class => jam_isa_child} Class},
    findall Class Known {check Self Unknown number, check Self Unknown Class},
    findall Item Items {
      member [1, nope, 2] Item,
      check Self Item number
    },
    not {check Self Wrong number, = Wrong nope},
    not {check Self Conflict number, check Self Conflict string},
    = Result [Open, Linked, Classes, Known, Items].

    exercise #{class => jam_isa_probe} Result.
    in_domain Selected [1, nope].
    freeze Selected {= Awoke Selected}.
    check #{class => jam_isa_probe} Selected number.
    """

    expected = %{
      "$Self" => {:"$var", "Self"},
      "$Class" => {:"$var", "Class"},
      "$_Self" => {:"$var", "_Self"},
      "$Classes" => {:"$var", "Classes"},
      "$Result" => [7, 8, [:jam_isa_child, :jam_isa_parent, :value, :object], [:number], [1, 2]],
      "$Items" => {:"$var", "Items"},
      "$Item" => {:"$var", "Item"},
      "$Selected" => 1,
      "$Object" => {:"$var", "Object"},
      "$Open" => {:"$var", "Open"},
      "$Alias" => {:"$var", "Alias"},
      "$Awoke" => 1,
      "$Unknown" => {:"$var", "Unknown"},
      "$Linked" => {:"$var", "Linked"},
      "$LinkedClass" => {:"$var", "LinkedClass"},
      "$Known" => {:"$var", "Known"},
      "$Wrong" => {:"$var", "Wrong"},
      "$Conflict" => {:"$var", "Conflict"}
    }

    {:atomic, {actual, _, _}} = evaluate(source)
    assert actual == expected
    assert [7, 8, classes, [:number], [1, 2]] = actual["$Result"]
    assert :jam_isa_child in classes
    assert :jam_isa_parent in classes
    assert actual["$Selected"] == 1
    assert actual["$Awoke"] == 1
  end

  example incremental_head_unification_preserves_map_keys_and_binding_order() do
    source = ~S"""
    @jam_incremental_match #{super => value}.

    jam_incremental_match >> same
    | _Self Value Value |.

    jam_incremental_match >> exercise
    | Self Result |
    = Key fixed,
    dif Item red,
    same Self [#{Key => [Item]}] [#{fixed => [blue]}],
    same Self [Head . Tail] [ready, done],
    not {same Self [Cycle] [[Cycle]]},
    not {same Self [MapCycle] [#{item => MapCycle}]},
    not {same Self [Late, #{Late => yes}] [fixed, #{fixed => yes}]},
    findall Choice Choices {
      member [red, blue] Choice,
      same Self [Choice, #{Key => Choice}] [blue, #{fixed => blue}]
    },
    = Result [Item, Head, Tail, Choices].

    exercise #{class => jam_incremental_match} Result.
    """

    {:atomic, {actual, _, _}} = evaluate(source)
    assert actual["$Result"] == [:blue, :ready, [:done], [:blue]]
  end

  example variable_references_preserve_nested_terms_constraints_and_occurs_checks() do
    source = ~S"""
    @jam_binding_probe #{super => value}.

    jam_binding_probe >> same
    | _Self Value Value |.

    jam_binding_probe >> exercise
    | Self Result |
    = Alias Original,
    = Original [#{item => Item} . Tail],
    dif Item red,
    same Self Alias [#{item => blue}, done],
    findall Choice Choices {
      member [red, blue] Choice,
      same Self [Choice] [blue]
    },
    not {= Cycle [Cycle]},
    not {= MapCycle #{item => MapCycle}},
    = Result [Alias, Item, Tail, Choices].

    exercise #{class => jam_binding_probe} Result.
    """

    expected = %{
      "$Self" => {:"$var", "Self"},
      "$_Self" => {:"$var", "_Self"},
      "$Value" => {:"$var", "Value"},
      "$Result" => [[%{item: :blue}, :done], :blue, [:done], [:blue]],
      "$Tail" => {:"$var", "Tail"},
      "$Item" => {:"$var", "Item"},
      "$Alias" => {:"$var", "Alias"},
      "$Choice" => {:"$var", "Choice"},
      "$Choices" => {:"$var", "Choices"},
      "$Cycle" => {:"$var", "Cycle"},
      "$MapCycle" => {:"$var", "MapCycle"},
      "$Original" => {:"$var", "Original"}
    }

    {:atomic, {actual, _, _}} = evaluate(source)
    assert actual == expected
    assert actual["$Result"] == [[%{item: :blue}, :done], :blue, [:done], [:blue]]
  end

  example compiled_methods_preserve_recursive_alternatives_repeated_variables_and_constraints() do
    source = ~S"""
    @compiled_probe #{super => object}.

    compiled_probe >> choose
    | _Self X Result |
    dif Local red,
    member [red, blue, green] Local,
    = Result [X, Local].

    vm_set_class compiled_instance compiled_probe.
    findall R Results {choose compiled_instance value R}.
    findall X Members {member [red, blue, red] X}.
    dif Selected red.
    member [red, blue] Selected.
    member [Head . Tail] red.
    = Tail [].
    """

    expected = %{
      "$Head" => :red,
      "$_Self" => {:"$var", "_Self"},
      "$X" => {:"$var", "X"},
      "$Result" => {:"$var", "Result"},
      "$Tail" => [],
      "$Selected" => :blue,
      "$Local" => {:"$var", "Local"},
      "$Results" => [[:value, :blue], [:value, :green]],
      "$Members" => [:red, :blue, :red]
    }

    {:atomic, {actual, _, _}} = evaluate(source)
    assert actual == expected
    assert actual["$Results"] == [[:value, :blue], [:value, :green]]
    assert actual["$Members"] == [:red, :blue, :red]
    assert actual["$Head"] == :red
  end

  example native_suspensions_follow_aliases_and_restore_on_backtracking() do
    source = ~S"""
    @jam_suspend_probe #{super => value}.

    jam_suspend_probe >> delayed
    | _Self Trigger Result |
    freeze Trigger {= Result ready}.

    jam_suspend_probe >> exercise
    | Self Result |
    delayed Self Trigger Ready,
    = Trigger Alias,
    = Alias go,
    string_codes Text [104 . Tail],
    = Tail [105],
    findall Color Colors {
      freeze Color {dif Color red},
      member [red, blue] Color
    },
    findall Number Numbers {
      freeze Gate {member [1, 2] Number},
      = Gate open
    },
    findall Value Empty {freeze Never {= Value unreachable}},
    = Result [Ready, Text, Colors, Numbers, Empty].

    exercise #{class => jam_suspend_probe} Result.
    """

    expected = %{
      "$Self" => {:"$var", "Self"},
      "$_Self" => {:"$var", "_Self"},
      "$Value" => {:"$var", "Value"},
      "$Text" => {:"$var", "Text"},
      "$Result" => [:ready, "hi", [:blue], [1, 2], []],
      "$Ready" => {:"$var", "Ready"},
      "$Tail" => {:"$var", "Tail"},
      "$Number" => {:"$var", "Number"},
      "$Color" => {:"$var", "Color"},
      "$Empty" => {:"$var", "Empty"},
      "$Numbers" => {:"$var", "Numbers"},
      "$Colors" => {:"$var", "Colors"},
      "$Alias" => {:"$var", "Alias"},
      "$Never" => {:"$var", "Never"},
      "$Trigger" => {:"$var", "Trigger"},
      "$Gate" => {:"$var", "Gate"}
    }

    {:atomic, {actual, _, _}} = evaluate(source)
    assert actual == expected
    assert actual["$Result"] == [:ready, "hi", [:blue], [1, 2], []]
  end

  example native_suspensions_survive_method_returns() do
    source = ~S"""
    @jam_suspend_boundary #{super => value}.

    jam_suspend_boundary >> delayed
    | _Self Trigger Result |
    freeze Trigger {= Result ready}.

    jam_suspend_boundary >> exercise
    | _Self Result |
    freeze Trigger {= Result ready},
    not {fail},
    = Trigger go.

    exercise #{class => jam_suspend_boundary} Handoff.
    delayed #{class => jam_suspend_boundary} Trigger Returned.
    = Trigger Alias.
    = Alias go.
    """

    expected = %{
      "$_Self" => {:"$var", "_Self"},
      "$Result" => {:"$var", "Result"},
      "$Alias" => :go,
      "$Handoff" => :ready,
      "$Returned" => :ready,
      "$Trigger" => :go
    }

    {:atomic, {actual, _, _}} = evaluate(source)
    assert actual == expected
    assert actual["$Handoff"] == :ready
    assert actual["$Returned"] == :ready
  end

  example relational_reads_enumerate_in_order_and_freshen_each_clause() do
    source = ~S"""
    @jam_read_parent #{super => value}.
    @jam_read_child #{super => jam_read_parent}.

    jam_read_child >> pick
    | [] red |.

    jam_read_child >> pick
    | [] blue |.

    jam_read_child >> pair
    | _Self X X |.

    jam_read_child >> exercise
    | Self Result |
    class Self Class,
    super Class Parent,
    method Class pick Method,
    findall Color Colors {clause Method [[], Color] {}},
    findall Color Reds {clause Method [[], Color] {}, == Color red},
    method Class pair Pair,
    clause Pair [_First, A, B] {},
    = A red,
    = B red,
    clause Pair [_Second, C, D] {},
    = C blue,
    = D blue,
    = Result [Class, Parent, Colors, Reds, A, C].

    exercise #{class => jam_read_child} Result.
    """

    expected = %{
      "$Self" => {:"$var", "Self"},
      "$Class" => {:"$var", "Class"},
      "$Method" => {:"$var", "Method"},
      "$_Self" => {:"$var", "_Self"},
      "$C" => {:"$var", "C"},
      "$Parent" => {:"$var", "Parent"},
      "$X" => {:"$var", "X"},
      "$Result" => [:jam_read_child, :jam_read_parent, [:red, :blue], [:red], :red, :blue],
      "$A" => {:"$var", "A"},
      "$B" => {:"$var", "B"},
      "$Color" => {:"$var", "Color"},
      "$D" => {:"$var", "D"},
      "$Pair" => {:"$var", "Pair"},
      "$Colors" => {:"$var", "Colors"},
      "$Reds" => {:"$var", "Reds"},
      "$_First" => {:"$var", "_First"},
      "$_Second" => {:"$var", "_Second"}
    }

    {:atomic, {actual, _, _}} = evaluate(source)
    assert actual == expected

    assert actual["$Result"] == [
             :jam_read_child,
             :jam_read_parent,
             [:red, :blue],
             [:red],
             :red,
             :blue
           ]
  end

  example relational_reads_preserve_open_links_and_delayed_owners() do
    source = ~S"""
    @jam_open_read_parent #{super => value}.
    @jam_open_read_child #{super => jam_open_read_parent}.

    jam_open_read_child >> chosen
    | [] red |.

    jam_open_read_child >> exercise
    | _Self Result |
    class Object Class,
    = Class jam_open_read_child,
    = Object #{class => jam_open_read_child},
    super Child Parent,
    = Child jam_open_read_child,
    = Parent jam_open_read_parent,
    method Owner chosen Method,
    = Owner jam_open_read_child,
    clause Method [[], Color] {},
    clause Other [[], red] {},
    method jam_open_read_child chosen Other,
    = Result [Class, Parent, Color].

    exercise #{class => jam_open_read_child} Result.
    """

    expected = %{
      "$Class" => {:"$var", "Class"},
      "$Method" => {:"$var", "Method"},
      "$_Self" => {:"$var", "_Self"},
      "$Parent" => {:"$var", "Parent"},
      "$Child" => {:"$var", "Child"},
      "$Other" => {:"$var", "Other"},
      "$Result" => [:jam_open_read_child, :jam_open_read_parent, :red],
      "$Owner" => {:"$var", "Owner"},
      "$Object" => {:"$var", "Object"},
      "$Color" => {:"$var", "Color"}
    }

    {:atomic, {actual, _, _}} = evaluate(source)
    assert actual == expected
    assert actual["$Result"] == [:jam_open_read_child, :jam_open_read_parent, :red]
  end

  example open_owner_constraints_preserve_aliases_and_failure() do
    source = ~S"""
    @jam_owner_a #{super => value}.
    @jam_owner_b #{super => value}.

    jam_owner_a >> owner_marker
    | [] owner_red |.

    jam_owner_b >> owner_marker
    | [] owner_blue |.

    jam_owner_a >> choose_owner
    | _Self Owner Color |
    method Owner owner_marker Method,
    = Owner Alias,
    member [jam_owner_a, jam_owner_b] Alias,
    clause Method [[], Color] {}.

    jam_owner_a >> delayed_clause
    | _Self Method Color |
    clause Method [[], Color] {},
    not {fail},
    method jam_owner_b owner_marker Method.

    jam_owner_a >> exercise
    | Self Result |
    findall [Owner, Color] Answers {choose_owner Self Owner Color},
    findall Bad Empty {method Bad no_such_owner_marker _, = Bad jam_owner_a},
    delayed_clause Self _Method Chosen,
    = Result [Answers, Empty, Chosen].

    exercise #{class => jam_owner_a} Result.
    """

    expected = %{
      "$Self" => {:"$var", "Self"},
      "$Method" => {:"$var", "Method"},
      "$_Self" => {:"$var", "_Self"},
      "$Result" => [[[:jam_owner_a, :owner_red], [:jam_owner_b, :owner_blue]], [], :owner_blue],
      "$Owner" => {:"$var", "Owner"},
      "$_Method" => {:"$var", "_Method"},
      "$Color" => {:"$var", "Color"},
      "$Empty" => {:"$var", "Empty"},
      "$Answers" => {:"$var", "Answers"},
      "$Alias" => {:"$var", "Alias"},
      "$Chosen" => {:"$var", "Chosen"},
      "$Bad" => {:"$var", "Bad"}
    }

    {:atomic, {actual, _, _}} = evaluate(source)
    assert actual == expected

    assert actual["$Result"] == [
             [[:jam_owner_a, :owner_red], [:jam_owner_b, :owner_blue]],
             [],
             :owner_blue
           ]
  end

  example native_negation_preserves_isolation_floundering_and_nested_choices() do
    source = ~S"""
    @jam_negation_probe #{super => value}.

    jam_negation_probe >> exercise
    | _Self Result |
    not {= Local changed, fail},
    var Local,
    findall X Kept {member [red, blue] X, not {= X red}},
    not {not {= 1 1}},
    not {freeze Never {fail}},
    not {in_domain Item [red, blue], member [green] Item},
    findall X Empty {not {member [red, blue] X}},
    = Result [Kept, Empty].

    exercise #{class => jam_negation_probe} Result.
    """

    expected = %{
      "$_Self" => {:"$var", "_Self"},
      "$X" => {:"$var", "X"},
      "$Result" => [[:blue], []],
      "$Item" => {:"$var", "Item"},
      "$Local" => {:"$var", "Local"},
      "$Empty" => {:"$var", "Empty"},
      "$Kept" => {:"$var", "Kept"},
      "$Never" => {:"$var", "Never"}
    }

    {:atomic, {actual, _, _}} = evaluate(source)
    assert actual == expected
    assert actual["$Result"] == [[:blue], []]
  end

  example native_failed_unification_preserves_constraint_diagnostics() do
    source = ~S"""
    @jam_failure_probe #{super => value}.

    jam_failure_probe >> rejected
    | _Self |
    dif X forbidden,
    = X forbidden.

    rejected #{class => jam_failure_probe}.
    """

    {:aborted, failure} = evaluate(source, trace: [])
    assert match?({:constraint_violated, {:dif, _, _}}, failure.reason)
  end

  example native_send_misses_preserve_overrides_and_handler_invalidation() do
    source = ~S"""
    @jam_miss_parent #{super => value}.
    @jam_miss_child #{super => jam_miss_parent}.

    jam_miss_parent >> choose
    | _Self missing parent |.

    jam_miss_child >> choose
    | _Self accepted own |.

    jam_miss_child >> attempt
    | Self Result |
    choose Self missing Result.

    jam_miss_child >> absent
    | Self |
    not {attempt Self _}.

    jam_miss_child >> attempt_absent
    | Self Result |
    unknown Self Result.

    = Receiver #{class => jam_miss_child}.
    not {attempt_absent Receiver _}.
    defmethod jam_miss_child unknown [_Self, direct] {}.
    attempt_absent Receiver Installed.
    vm_retract_method jam_miss_child unknown _.
    not {attempt_absent Receiver _}.
    absent Receiver.
    defmethod jam_miss_child does_not_understand [_Self, choose, [missing, Answer]] {= Answer handled}.
    defmethod jam_miss_child does_not_understand [_Self, unknown, [Answer]] {= Answer intercepted}.
    attempt Receiver Result.
    attempt_absent Receiver Intercepted.
    vm_retract_method jam_miss_child does_not_understand _.
    absent Receiver.
    """

    expected = %{
      "$Self" => {:"$var", "Self"},
      "$_Self" => {:"$var", "_Self"},
      "$Result" => :handled,
      "$Receiver" => %{class: :jam_miss_child},
      "$Answer" => {:"$var", "Answer"},
      "$Installed" => :direct,
      "$Intercepted" => :intercepted
    }

    {:atomic, {actual, _, _}} = evaluate(source)
    assert actual == expected
    assert actual["$Result"] == :handled
    assert actual["$Installed"] == :direct
    assert actual["$Intercepted"] == :intercepted

    {:aborted, failure} = evaluate(~S"attempt_absent #{class => jam_miss_child} _.")
    assert {:does_not_understand, %{class: :jam_miss_child}, :unknown, 1, _} = failure.reason
  end

  example shallow_map_heads_preserve_keys_aliases_and_open_construction() do
    source = ~S"""
    @jam_map_head_probe #{super => value}.

    jam_map_head_probe >> capture
    | _Self #{payload => Payload} Payload |.

    jam_map_head_probe >> exercise
    | Self Result |
    = Key payload,
    capture Self #{Key => [#{Nested => Item} . Tail]} Captured,
    = Nested value,
    = Item shared,
    = Tail [end],
    capture Self Built Captured,
    = Other value,
    capture Self #{payload => #{Other => shared}} #{value => shared},
    = Result [Captured, Built].

    exercise #{class => jam_map_head_probe} Result.
    """

    {:atomic, {actual, _, _}} = evaluate(source)

    assert actual["$Result"] == [
             [%{value: :shared}, :end],
             %{payload: [%{value: :shared}, :end]}
           ]
  end

  example provider_cursors_survive_nested_sends_and_backtracking() do
    source = ~S"""
    @jam_cursor_root #{super => value}.
    @jam_cursor_middle #{super => jam_cursor_root}.
    @jam_cursor_child #{super => jam_cursor_middle}.

    jam_cursor_root >> pick
    | _Self red |.

    jam_cursor_root >> pick
    | _Self blue |.

    jam_cursor_root >> noise
    | _Self root_noise |.

    jam_cursor_middle >> noise
    | Self [middle, Parent] |
    call_next_method Self Parent.

    jam_cursor_middle >> pick
    | Self [middle, Parent] |
    call_next_method Self Parent.

    jam_cursor_child >> pick
    | Self [Noise, Parent] |
    noise Self Noise,
    in_domain Gate [ready],
    call_next_method Self Parent.

    findall Result Results {pick #{class => jam_cursor_child} Result}.
    """

    expected = %{
      "$Self" => {:"$var", "Self"},
      "$_Self" => {:"$var", "_Self"},
      "$Parent" => {:"$var", "Parent"},
      "$Results" => [
        [[:middle, :root_noise], [:middle, :red]],
        [[:middle, :root_noise], [:middle, :blue]]
      ],
      "$Gate" => {:"$var", "Gate"},
      "$Noise" => {:"$var", "Noise"}
    }

    {:atomic, {actual, _, _}} = evaluate(source)
    assert actual == expected

    assert actual["$Results"] == [
             [[:middle, :root_noise], [:middle, :red]],
             [[:middle, :root_noise], [:middle, :blue]]
           ]
  end

  example provider_cursors_observe_method_edits_and_do_not_send_misses_to_dnu() do
    source = ~S"""
    @jam_cursor_edit_root #{super => value}.
    @jam_cursor_edit_child #{super => jam_cursor_edit_root}.

    jam_cursor_edit_root >> edited
    | _Self old |.

    jam_cursor_edit_child >> edited
    | Self Result |
    defmethod jam_cursor_edit_root edited [_Self, new] {},
    call_next_method Self Result.

    jam_cursor_edit_root >> strict
    | _Self accepted |.

    jam_cursor_edit_child >> strict
    | Self Value |
    call_next_method Self Value.

    jam_cursor_edit_child >> does_not_understand
    | _Self _Selector _Args |.

    = Receiver #{class => jam_cursor_edit_child}.
    findall Value Results {edited Receiver Value}.
    not {strict Receiver rejected}.
    """

    expected = %{
      "$Self" => {:"$var", "Self"},
      "$_Self" => {:"$var", "_Self"},
      "$Value" => {:"$var", "Value"},
      "$_Args" => {:"$var", "_Args"},
      "$Result" => {:"$var", "Result"},
      "$Receiver" => %{class: :jam_cursor_edit_child},
      "$Results" => [:old, :new],
      "$_Selector" => {:"$var", "_Selector"}
    }

    {:atomic, {actual, _, _}} = evaluate(source)
    assert actual == expected
    assert actual["$Results"] == [:old, :new]
  end

  example frozen_next_method_calls_reach_the_parent() do
    source = ~S"""
    @jam_cursor_fallback_root #{super => value}.
    @jam_cursor_fallback_middle #{super => jam_cursor_fallback_root}.
    @jam_cursor_fallback_child #{super => jam_cursor_fallback_middle}.

    jam_cursor_fallback_root >> pick
    | _Self inherited |.

    jam_cursor_fallback_middle >> pick
    | Self Result |
    freeze Gate {call_next_method Self Result},
    = Gate ready.

    jam_cursor_fallback_child >> pick
    | Self Result |
    call_next_method Self Result.

    pick #{class => jam_cursor_fallback_child} Result.
    """

    expected = %{
      "$Self" => {:"$var", "Self"},
      "$_Self" => {:"$var", "_Self"},
      "$Result" => :inherited,
      "$Gate" => {:"$var", "Gate"}
    }

    {:atomic, {actual, _, _}} = evaluate(source)
    assert actual == expected
    assert actual["$Result"] == :inherited
  end

  example nested_provider_calls_preserve_control_scope_and_search_isolation() do
    source = ~S"""
    @jam_nested_cursor_root #{super => value}.
    @jam_nested_cursor_child #{super => jam_nested_cursor_root}.

    jam_nested_cursor_root >> pick
    | _Self red |.

    jam_nested_cursor_root >> pick
    | _Self blue |.

    jam_nested_cursor_child >> pick
    | Self Result |
    fail -> = Result unreachable ; call_next_method Self Result.

    jam_nested_cursor_root >> branch
    | _Self inherited |.

    jam_nested_cursor_child >> branch
    | Self Result |
    call_next_method Self Result ; = Result local.

    jam_nested_cursor_root >> condition
    | _Self red |.

    jam_nested_cursor_root >> condition
    | _Self blue |.

    jam_nested_cursor_child >> condition
    | Self Result |
    call_next_method Self Result -> pass.

    jam_nested_cursor_root >> isolated
    | _Self parent |.

    jam_nested_cursor_child >> isolated
    | Self Results |
    not {call_next_method Self _},
    findall X Empty {call_next_method Self X},
    call_next_method Self Parent,
    = Results [Empty, Parent].

    findall Color Colors {pick #{class => jam_nested_cursor_child} Color}.
    findall Value Values {branch #{class => jam_nested_cursor_child} Value}.
    isolated #{class => jam_nested_cursor_child} Isolated.
    findall Choice Choices {condition #{class => jam_nested_cursor_child} Choice}.
    """

    expected = %{
      "$Self" => {:"$var", "Self"},
      "$_Self" => {:"$var", "_Self"},
      "$Values" => [:inherited, :local],
      "$Parent" => {:"$var", "Parent"},
      "$X" => {:"$var", "X"},
      "$Result" => {:"$var", "Result"},
      "$Results" => {:"$var", "Results"},
      "$Empty" => {:"$var", "Empty"},
      "$Colors" => [:red, :blue],
      "$Isolated" => [[], :parent],
      "$Choices" => [:red]
    }

    {:atomic, {actual, _, _}} = evaluate(source)
    assert actual == expected
    assert actual["$Colors"] == [:red, :blue]
    assert actual["$Values"] == [:inherited, :local]
    assert actual["$Isolated"] == [[], :parent]
    assert actual["$Choices"] == [:red]
  end

  example native_map_pairs_preserves_modes_constraints_and_delayed_inputs() do
    source = ~S"""
    @jam_pairs_probe #{super => value}.

    jam_pairs_probe >> exercise
    | _Self Result |
    map_pairs #{b => 2, a => 1} Sorted,
    map_pairs #{b => 2, a => 1} [[b, B], [a, 1]],
    map_pairs Built [[Key, Value] . Tail],
    = Key Alias,
    = Alias k,
    = Tail [[j, other]],
    = Value shared,
    map_pairs Later Entries,
    = Entries [[z, last]],
    map_get Constrained a A,
    map_pairs Constrained [[a, 1], [b, 2]],
    findall Map Maps {member [red, blue] Color, map_pairs Map [[color, Color]]},
    not {map_pairs _ [[a, 1], [a, 2]]},
    not {map_pairs invalid _},
    = Result [Sorted, B, Built, Later, A, Maps].

    exercise #{class => jam_pairs_probe} Result.
    """

    expected = %{
      "$_Self" => {:"$var", "_Self"},
      "$Value" => {:"$var", "Value"},
      "$Key" => {:"$var", "Key"},
      "$Result" => [
        [[:a, 1], [:b, 2]],
        2,
        %{k: :shared, j: :other},
        %{z: :last},
        1,
        [%{color: :red}, %{color: :blue}]
      ],
      "$Sorted" => {:"$var", "Sorted"},
      "$Map" => {:"$var", "Map"},
      "$Entries" => {:"$var", "Entries"},
      "$Tail" => {:"$var", "Tail"},
      "$A" => {:"$var", "A"},
      "$B" => {:"$var", "B"},
      "$Color" => {:"$var", "Color"},
      "$Built" => {:"$var", "Built"},
      "$Maps" => {:"$var", "Maps"},
      "$Alias" => {:"$var", "Alias"},
      "$Later" => {:"$var", "Later"},
      "$Constrained" => {:"$var", "Constrained"}
    }

    {:atomic, {actual, _, _}} = evaluate(source)
    assert actual == expected

    assert actual["$Result"] == [
             [[:a, 1], [:b, 2]],
             2,
             %{k: :shared, j: :other},
             %{z: :last},
             1,
             [%{color: :red}, %{color: :blue}]
           ]
  end

  example self_sends_preserve_overrides_and_method_edits() do
    source = ~S"""
    @jam_self_parent #{super => value}.
    @jam_self_child #{super => jam_self_parent}.

    jam_self_parent >> ping
    | _Self parent |.

    jam_self_child >> ping
    | _Self child |.

    jam_self_parent >> exercise
    | Self Before After |
    ping Self Before,
    install Self,
    findall Value After {ping Self Value}.

    jam_self_parent >> install
    | _Self |
    defmethod jam_self_child ping [_Receiver, replacement] {}.

    exercise #{class => jam_self_child} Before After.
    """

    expected = %{
      "$Self" => {:"$var", "Self"},
      "$_Self" => {:"$var", "_Self"},
      "$Value" => {:"$var", "Value"},
      "$After" => [:child, :replacement],
      "$_Receiver" => {:"$var", "_Receiver"},
      "$Before" => :child
    }

    {:atomic, {actual, _, _}} = evaluate(source)
    assert actual == expected
    assert actual["$Before"] == :child
    assert actual["$After"] == [:child, :replacement]
  end

  example self_sends_recheck_variable_keys_when_the_receiver_class_changes() do
    source = ~S"""
    @jam_self_key_child #{super => value}.

    map >> jam_self_key_ping
    | _Self plain |.

    jam_self_key_child >> jam_self_key_ping
    | _Self classed |.

    map >> jam_self_key_exercise
    | Self Key Before After |
    jam_self_key_ping Self Before,
    = Key class,
    jam_self_key_ping Self After.

    jam_self_key_exercise #{Key => jam_self_key_child} Key Before After.
    """

    expected = %{
      "$Self" => {:"$var", "Self"},
      "$_Self" => {:"$var", "_Self"},
      "$Key" => :class,
      "$After" => :classed,
      "$Before" => :plain
    }

    {:atomic, {actual, _, _}} = evaluate(source)
    assert actual == expected
    assert actual["$Before"] == :plain
    assert actual["$After"] == :classed
  end

  example primitive_instructions_preserve_modes_constraints_and_backtracking() do
    source = ~S"""
    @jam_primitive_probe #{super => object}.

    jam_primitive_probe >> convert
    | _Self Text Atom Codes |
    atom_string Atom Text,
    atom Atom,
    string_codes Text Codes.

    jam_primitive_probe >> decompose
    | _Self Term Name Args |
    functor Term Name Args.

    jam_primitive_probe >> exercise
    | Self Result |
    convert Self "hé" Word Codes,
    convert Self Text hello [104, 101, 108, 108, 111],
    decompose Self Built greet [world],
    decompose Self Built Name Args,
    == Args [world],
    findall Cs Answers {member [42, "ok"] Input, convert Self Input _ Cs},
    dif Bad forbidden,
    not {convert Self "forbidden" Bad _},
    not {convert Self "ok" _ [0]},
    = Result [Word, Codes, Text, Name, Args, Answers].

    vm_set_class jam_primitive_instance jam_primitive_probe.
    exercise jam_primitive_instance Result.
    """

    expected = %{
      "$Self" => {:"$var", "Self"},
      "$Args" => {:"$var", "Args"},
      "$_Self" => {:"$var", "_Self"},
      "$Text" => {:"$var", "Text"},
      "$Name" => {:"$var", "Name"},
      "$Codes" => {:"$var", "Codes"},
      "$Result" => [:hé, [104, 233], "hello", :greet, [:world], [~c"ok"]],
      "$Cs" => {:"$var", "Cs"},
      "$Input" => {:"$var", "Input"},
      "$Word" => {:"$var", "Word"},
      "$Term" => {:"$var", "Term"},
      "$Atom" => {:"$var", "Atom"},
      "$Built" => {:"$var", "Built"},
      "$Answers" => {:"$var", "Answers"},
      "$Bad" => {:"$var", "Bad"}
    }

    {:atomic, {actual, _, _}} = evaluate(source)
    assert actual == expected
    assert actual["$Result"] == [:hé, [104, 233], "hello", :greet, [:world], [[111, 107]]]
  end

  example shallow_primitive_reads_preserve_bound_cells_and_delayed_elements() do
    source = ~S"""
    @jam_demand_probe #{super => object}.

    jam_demand_probe >> codes
    | _Self Text Codes |
    string_codes Text Codes.

    jam_demand_probe >> delayed
    | Self Text |
    codes Self Text [Head . Tail],
    = Head 104,
    = Tail [105].

    jam_demand_probe >> shape
    | _Self Value |
    not {var Value},
    not {atom Value},
    freeze Value {= Value [allowed]}.

    vm_set_class jam_demand_instance jam_demand_probe.
    = First 104.
    = Rest [233].
    = Bound [First . Rest].
    codes jam_demand_instance Text Bound.
    delayed jam_demand_instance Delayed.
    findall Codes Answers {
      member ["hi", "hé"] Input,
      codes jam_demand_instance Input Codes
    }.
    shape jam_demand_instance [Element].
    dif Forbidden 104.
    not {codes jam_demand_instance "hi" [Forbidden, 105]}.
    not {codes jam_demand_instance _ [55296]}.
    not {codes jam_demand_instance _ [104 . bad_tail]}.
    """

    expected = %{
      "$Self" => {:"$var", "Self"},
      "$Head" => {:"$var", "Head"},
      "$_Self" => {:"$var", "_Self"},
      "$Value" => {:"$var", "Value"},
      "$Text" => "hé",
      "$Rest" => [233],
      "$Codes" => {:"$var", "Codes"},
      "$First" => 104,
      "$Tail" => {:"$var", "Tail"},
      "$Answers" => [~c"hi", [104, 233]],
      "$Bound" => [104, 233],
      "$Delayed" => "hi",
      "$Element" => :allowed,
      "$Forbidden" => {:"$var", "Forbidden"}
    }

    expected_constraints = %{"$Forbidden" => %{dif: ~c"h"}}
    {:atomic, {actual, actual_constraints, _}} = evaluate(source)
    assert actual == expected
    assert actual_constraints == expected_constraints
    assert actual["$Text"] == "hé"
    assert actual["$Delayed"] == "hi"
    assert actual["$Answers"] == [[104, 105], [104, 233]]
    assert actual["$Element"] == :allowed
  end

  example primitive_suspensions_resume_after_later_bindings() do
    source = ~S"""
    @jam_wait_probe #{super => object}.

    jam_wait_probe >> atom_later
    | _Self Atom |
    atom_string Atom Text,
    = Text "ready".

    jam_wait_probe >> codes_later
    | _Self Text |
    string_codes Text [104 . Tail],
    = Tail [105].

    jam_wait_probe >> term_later
    | _Self Term |
    functor Term Name Args,
    = Name greet,
    = Args [world].

    vm_set_class jam_wait_instance jam_wait_probe.
    atom_later jam_wait_instance Atom.
    codes_later jam_wait_instance Text.
    term_later jam_wait_instance Term.
    functor Term Name Args.
    """

    expected = %{
      "$Args" => [:world],
      "$_Self" => {:"$var", "_Self"},
      "$Text" => "hi",
      "$Name" => :greet,
      "$Term" => %AL.Goal.Compound{args: [:world], name: :greet},
      "$Tail" => {:"$var", "Tail"},
      "$Atom" => :ready
    }

    {:atomic, {actual, _, _}} = evaluate(source)
    assert actual == expected
    assert actual["$Atom"] == :ready
    assert actual["$Text"] == "hi"
    assert actual["$Name"] == :greet
    assert actual["$Args"] == [:world]
  end

  example indexed_heads_preserve_order_open_modes_and_dynamic_arguments() do
    source = ~S"""
    @jam_index_probe #{super => object}.

    jam_index_probe >> pick
    | _Self red first |.

    jam_index_probe >> pick
    | _Self _ fallback |.

    jam_index_probe >> pick
    | _Self blue last |.

    jam_index_probe >> shape
    | _Self [] empty |.

    jam_index_probe >> shape
    | _Self [_ . _] cons |.

    jam_index_probe >> shape
    | _Self _ any |.

    jam_index_probe >> exercise
    | Self Result |
    findall R Reds {pick Self red R},
    findall R Blues {pick Self blue R},
    findall R Open {pick Self _ R},
    findall R Empty {shape Self [] R},
    findall R Cons {shape Self [item] R},
    findall R Shapes {shape Self _ R},
    dif Color red,
    findall R Constrained {pick Self Color R},
    = Args [blue, R],
    findall R Dynamic {send Self pick Args},
    = Result [Reds, Blues, Open, Empty, Cons, Shapes, Constrained, Dynamic].

    vm_set_class jam_index_instance jam_index_probe.
    exercise jam_index_instance Result.
    """

    expected = %{
      "$Self" => {:"$var", "Self"},
      "$Args" => {:"$var", "Args"},
      "$_Self" => {:"$var", "_Self"},
      "$Result" => [
        [:first, :fallback],
        [:fallback, :last],
        [:first, :fallback, :last],
        [:empty, :any],
        [:cons, :any],
        [:empty, :cons, :any],
        [:fallback, :last],
        [:fallback, :last]
      ],
      "$R" => {:"$var", "R"},
      "$Color" => {:"$var", "Color"},
      "$Open" => {:"$var", "Open"},
      "$Empty" => {:"$var", "Empty"},
      "$Cons" => {:"$var", "Cons"},
      "$Shapes" => {:"$var", "Shapes"},
      "$Constrained" => {:"$var", "Constrained"},
      "$Reds" => {:"$var", "Reds"},
      "$Blues" => {:"$var", "Blues"},
      "$Dynamic" => {:"$var", "Dynamic"}
    }

    {:atomic, {actual, _, _}} = evaluate(source)
    assert actual == expected

    assert actual["$Result"] == [
             [:first, :fallback],
             [:fallback, :last],
             [:first, :fallback, :last],
             [:empty, :any],
             [:cons, :any],
             [:empty, :cons, :any],
             [:fallback, :last],
             [:fallback, :last]
           ]
  end

  example caller_arguments_preserve_aliases_open_structures_and_variadic_calls() do
    source = ~S"""
    @jam_argument_probe #{super => object}.

    jam_argument_probe >> exercise
    | Self Result |
    dif Open forbidden,
    pair Self Open Open,
    = Open [blue],
    = Args [Open, Open],
    send Self pair Args,
    variadic Self Open result extra,
    not {pair Self [red] [blue]},
    not {pair Self Open Open extra},
    = Result Open.

    jam_argument_probe >> pair
    | _Self [Item] [Item] |.

    jam_argument_probe >> variadic
    | _Self [blue] . Rest |
    = Rest [result, extra].

    vm_set_class jam_argument_instance jam_argument_probe.
    exercise jam_argument_instance Result.
    """

    expected = %{
      "$Self" => {:"$var", "Self"},
      "$Args" => {:"$var", "Args"},
      "$_Self" => {:"$var", "_Self"},
      "$Rest" => {:"$var", "Rest"},
      "$Result" => [:blue],
      "$Item" => {:"$var", "Item"},
      "$Open" => {:"$var", "Open"}
    }

    {:atomic, {actual, _, _}} = evaluate(source)
    assert actual == expected
    assert actual["$Result"] == [:blue]
  end

  example open_structured_heads_keep_generation_modes() do
    source = ~S"""
    concat [a, b] [c] Result.
    findall [Left, Right] Splits {concat Left Right [a, b]}.
    """

    expected = %{
      "$Result" => [:a, :b, :c],
      "$Splits" => [[[], [:a, :b]], [[:a], [:b]], [[:a, :b], []]]
    }

    {:atomic, {actual, _, _}} = evaluate(source)
    assert actual == expected
    assert actual["$Result"] == [:a, :b, :c]

    branch = %AL.Branch{id: Examples.Support.branch()}

    assert {:atomic, {:ok, store, 2}} =
             :mnesia.transaction(fn ->
               {:ok, _, id} = AL.Dispatch.target([:a, :b], :concat, branch)
               AL.JAM.run(id, [[:a, :b], [:c], {:"$var", "Result"}], %{}, branch, 100)
             end)

    assert AL.Var.subst({:"$var", "Result"}, store) == [:a, :b, :c]
  end

  example map_heads_match_exact_keys_and_construct_shared_constrained_values() do
    source = ~S"""
    @compiled_map_head_probe #{super => object}.

    compiled_map_head_probe >> pair
    | _Self #{left => X, right => [X]} X |.

    compiled_map_head_probe >> empty
    | _Self #{} |.

    vm_set_class compiled_map_head_instance compiled_map_head_probe.
    pair compiled_map_head_instance #{left => 7, right => [7]} Read.
    dif Value red.
    pair compiled_map_head_instance Made Value.
    = Value blue.
    empty compiled_map_head_instance Empty.
    not {pair compiled_map_head_instance #{left => 1, right => [2]} _}.
    not {pair compiled_map_head_instance #{left => 1, right => [1], extra => 0} _}.
    findall Result Results {
      {pair compiled_map_head_instance #{left => red, right => [blue]} Result}
        ; {pair compiled_map_head_instance #{left => green, right => [green]} Result}
    }.
    """

    expected = %{
      "$_Self" => {:"$var", "_Self"},
      "$Value" => :blue,
      "$X" => {:"$var", "X"},
      "$Read" => 7,
      "$Results" => [:green],
      "$Empty" => %{},
      "$Made" => %{left: :blue, right: [:blue]}
    }

    {:atomic, {actual, _, _}} = evaluate(source)
    assert actual == expected
    assert actual["$Made"] == %{left: :blue, right: [:blue]}
    assert actual["$Empty"] == %{}
    assert actual["$Results"] == [:green]
  end

  example method_edits_invalidate_the_compiled_method_within_a_transaction() do
    {:atomic, {bindings, _, _}} =
      evaluate(~S"""
      @compiled_edit_probe #{super => object}.

      compiled_edit_probe >> choose
      | _Self old |.

      vm_set_class compiled_edit_instance compiled_edit_probe.
      choose compiled_edit_instance old.
      defmethod compiled_edit_probe choose [_Self, new] {}.
      findall X Values {choose compiled_edit_instance X}.
      """)

    assert bindings["$Values"] == [:old, :new]
  end

  example compiled_sends_resolve_variable_keys_inside_list_receivers() do
    source = ~S"""
    list >> compiled_key_probe
    | [#{fixed => Value}] Value |.

    @compiled_receiver_probe #{super => object}.

    compiled_receiver_probe >> relay
    | _Self Receiver Value |
    compiled_key_probe Receiver Value.

    vm_set_class compiled_receiver_instance compiled_receiver_probe.
    = Key fixed.
    relay compiled_receiver_instance [#{Key => 7}] Result.
    """

    expected = %{
      "$_Self" => {:"$var", "_Self"},
      "$Value" => {:"$var", "Value"},
      "$Key" => :fixed,
      "$Result" => 7,
      "$Receiver" => {:"$var", "Receiver"}
    }

    {:atomic, {actual, _, _}} = evaluate(source)
    assert actual == expected
    assert actual["$Result"] == 7
  end

  example machine_operations_preserve_alternatives_and_equality_constraints() do
    source = ~S"""
    @compiled_operation_probe #{super => object}.

    compiled_operation_probe >> pick
    | _Self X |
    = X red,
    (pass).

    compiled_operation_probe >> pick
    | _Self _ |
    (fail).

    compiled_operation_probe >> pick
    | _Self X |
    = X blue.

    vm_set_class compiled_operation_instance compiled_operation_probe.
    findall X Values {pick compiled_operation_instance X}.
    dif Selected red.
    pick compiled_operation_instance Selected.
    """

    [definitions, query] = String.split(source, "findall X Values", parts: 2)
    {:atomic, _} = evaluate(definitions)
    source = "findall X Values" <> query

    {:atomic, {bindings, _constraints, _state}} = evaluate(source)
    assert bindings["$Values"] == [:red, :blue]
    assert bindings["$Selected"] == :blue
  end

  example explicit_operands_keep_shared_terms() do
    source = ~S"""
    @compiled_operand_probe #{super => object}.

    compiled_operand_probe >> build
    | _Self Key Value Tail Result |
    = Result #{Key => [Value, Value . Tail]},
    not {= Value forbidden}.

    compiled_operand_probe >> read
    | _Self Map Key Values |
    map_get Map Key Values.

    vm_set_class compiled_operand_instance compiled_operand_probe.
    build compiled_operand_instance Key shared Tail Built.
    = Key payload.
    = Tail [end].
    read compiled_operand_instance Built payload Values.
    findall Result Results {
      member [first, second] Item,
      build compiled_operand_instance payload Item [] Result
    }.
    """

    expected = %{
      "$_Self" => {:"$var", "_Self"},
      "$Value" => {:"$var", "Value"},
      "$Key" => :payload,
      "$Values" => [:shared, :shared, :end],
      "$Result" => {:"$var", "Result"},
      "$Map" => {:"$var", "Map"},
      "$Tail" => [:end],
      "$Results" => [%{payload: [:first, :first]}, %{payload: [:second, :second]}],
      "$Built" => %{payload: [:shared, :shared, :end]}
    }

    {:atomic, {actual, _, _}} = evaluate(source)
    assert actual == expected
    assert actual["$Values"] == [:shared, :shared, :end]
    assert actual["$Results"] == [%{payload: [:first, :first]}, %{payload: [:second, :second]}]
  end

  example anonymous_arguments_and_open_arithmetic_stay_in_the_machine() do
    source = ~S"""
    @jam_anonymous_probe #{super => value}.

    jam_anonymous_probe >> pair
    | _Self X Pair |
    = Pair [X, X].

    jam_anonymous_probe >> later
    | _Self X Y |
    = Y (+ X 1).

    jam_anonymous_probe >> exercise
    | Self Results |
    pair Self _ [A, B],
    = A shared,
    later Self N M,
    = N 4,
    = Results [B, M].

    exercise #{class => jam_anonymous_probe} Results.
    """

    expected = %{
      "$Self" => {:"$var", "Self"},
      "$_Self" => {:"$var", "_Self"},
      "$M" => {:"$var", "M"},
      "$N" => {:"$var", "N"},
      "$X" => {:"$var", "X"},
      "$Y" => {:"$var", "Y"},
      "$A" => {:"$var", "A"},
      "$B" => {:"$var", "B"},
      "$Results" => [:shared, 5],
      "$Pair" => {:"$var", "Pair"}
    }

    {:atomic, {actual, _, _}} = evaluate(source)
    assert actual == expected
    assert actual["$Results"] == [:shared, 5]
  end

  example retained_tracing_preserves_results() do
    expected = %{"$Values" => [:a, :b, :a]}

    {:atomic, {actual, _, state}} =
      evaluate("findall X Values {member [a, b, a] X}.", trace: [:domino, :vm])

    assert actual == expected
    assert state.trace.events != []
  end
end
