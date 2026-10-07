defmodule Examples.ALJAM do
  use ExExample
  import ExUnit.Assertions

  example compiled_methods_call_and_return_in_the_machine() do
    {:atomic, _} =
      evaluate_source(~S"""
      @machine_frame_probe #{super => object}.

      machine_frame_probe >> walk
      | _Self [] |.

      machine_frame_probe >> walk
      | Self [Head . Tail] |
      visit Self Head,
      walk Self Tail.

      machine_frame_probe >> visit
      | _Self _Value |
      (pass).

      vm_set_class machine_frame_instance machine_frame_probe.
      """)

    branch = %AL.Branch{id: Examples.Support.branch()}

    assert {:atomic, {:ok, %{}, 1002}} =
             :mnesia.transaction(fn ->
               {:ok, _, id} = AL.Dispatch.target(:machine_frame_instance, :walk, branch)

               AL.JAM.run(
                 id,
                 [:machine_frame_instance, Enum.to_list(1..1000)],
                 %{},
                 branch,
                 10_000
               )
             end)
  end

  example machine_preserves_constraints_failure_and_alternatives() do
    {:atomic, _} =
      evaluate_source(~S"""
      @machine_relation_probe #{super => object}.

      machine_relation_probe >> relay
      | Self X Result |
      choose Self X,
      = Result X.

      machine_relation_probe >> choose
      | _Self red |.

      machine_relation_probe >> choose
      | _Self blue |.

      vm_set_class machine_relation_instance machine_relation_probe.
      """)

    query = ~S"""
    findall X All {relay machine_relation_instance X X}.
    dif Chosen red.
    relay machine_relation_instance Chosen Result.
    not {relay machine_relation_instance green green}.
    """

    {:atomic, {bindings, constraints, _state}} = evaluate_source(query)
    result = {bindings, constraints}

    assert result == {%{"$Result" => :blue, "$All" => [:red, :blue], "$Chosen" => :blue}, %{}}
  end

  example machine_alternatives_restore_bindings_and_nested_return_frames_in_order() do
    {:atomic, _} =
      evaluate_source(~S"""
      @machine_choices_probe #{super => object}.

      machine_choices_probe >> pair
      | Self Pair |
      color Self Left,
      color Self Right,
      = Pair [Left, Right].

      machine_choices_probe >> color
      | _Self Color |
      = Color rejected,
      (fail).

      machine_choices_probe >> color
      | _Self red |.

      machine_choices_probe >> color
      | _Self blue |.

      vm_set_class machine_choices_instance machine_choices_probe.
      """)

    branch = %AL.Branch{id: Examples.Support.branch()}

    assert {:atomic, answers} =
             :mnesia.transaction(fn ->
               {:ok, _, id} = AL.Dispatch.target(:machine_choices_instance, :pair, branch)

               result =
                 AL.JAM.run(
                   id,
                   [:machine_choices_instance, {:"$var", "Pair"}],
                   %{},
                   branch,
                   1000
                 )

               machine_answers(result, [], branch)
             end)

    assert answers == [[:red, :red], [:red, :blue], [:blue, :red], [:blue, :blue]]
  end

  example mutations_preserve_alternatives_and_execute_effects_once_per_answer() do
    {:atomic, _} =
      evaluate_source(~S"""
      @machine_handoff_probe #{super => object, ivars => [#{name => seen}]}.

      machine_handoff_probe >> pair
      | Self Pair |
      color Self Left,
      record Self Left,
      color Self Right,
      = Pair [Left, Right].

      machine_handoff_probe >> color
      | _Self red |.

      machine_handoff_probe >> color
      | _Self blue |.

      machine_handoff_probe >> record
      | Self Color |
      get Self seen Seen,
      set_slot Self seen [Color . Seen].

      vm_set_class machine_handoff_instance machine_handoff_probe.
      """)

    {:atomic, {bindings, _, _}} =
      evaluate_source(~S"""
      set_slot machine_handoff_instance seen [].
      findall Pair Pairs {pair machine_handoff_instance Pair}.
      get machine_handoff_instance seen Seen.
      """)

    expected = bindings

    assert expected == %{
             "$Pairs" => [[:red, :red], [:red, :blue], [:blue, :red], [:blue, :blue]],
             "$Seen" => [:blue, :red]
           }

    assert expected["$Pairs"] == [[:red, :red], [:red, :blue], [:blue, :red], [:blue, :blue]]
    assert expected["$Seen"] == [:blue, :red]
  end

  example caller_cuts_prune_compiled_alternatives() do
    {:atomic, _} =
      evaluate_source(~S"""
      @machine_cut_probe #{super => object}.

      machine_cut_probe >> first
      | Self Color |
      color Self Color,
      (cut).

      machine_cut_probe >> color
      | _Self red |.

      machine_cut_probe >> color
      | _Self blue |.

      vm_set_class machine_cut_instance machine_cut_probe.
      """)

    {:atomic, {bindings, _, _}} =
      evaluate_source("findall Color Colors {first machine_cut_instance Color}.")

    assert bindings["$Colors"] == [:red]
  end

  example running_calls_keep_their_clauses_while_later_calls_see_edits() do
    {:atomic, {bindings, _, _}} =
      evaluate_source(~S"""
      @machine_edit_probe #{super => object}.

      machine_edit_probe >> pair
      | Self Left Right |
      color Self Left,
      value Self Right.

      machine_edit_probe >> color
      | _Self red |.

      machine_edit_probe >> color
      | _Self blue |.

      machine_edit_probe >> value
      | _Self old |.

      vm_set_class machine_edit_instance machine_edit_probe.
      findall [Left, Right] Pairs {
        pair machine_edit_instance Left Right,
        defmethod machine_edit_probe value [_Self, new] {}
      }.
      """)

    assert bindings["$Pairs"] == [[:red, :old], [:blue, :old], [:blue, :new]]
  end

  example yielded_answers_pass_current_bindings_back_to_callers() do
    {:atomic, _} =
      evaluate_source(~S"""
      @machine_return_probe #{super => object}.

      machine_return_probe >> pair
      | Self Pair |
      interpreted Self Value,
      = Pair [Value, Value].

      machine_return_probe >> interpreted
      | _Self Value |
      {= Value red} ; {= Value blue}.

      machine_return_probe >> delayed
      | Self Result |
      park Self Value Result,
      = Value ready.

      machine_return_probe >> park
      | _Self Value Result |
      freeze Value {= Result Value}.

      vm_set_class machine_return_instance machine_return_probe.
      """)

    {:atomic, {bindings, constraints, state}} =
      evaluate_source(~S"""
      findall Pair Pairs {pair machine_return_instance Pair}.
      delayed machine_return_instance Result.
      """)

    expected = {bindings, constraints, state.reductions}

    assert expected ==
             {%{"$Pairs" => [[:red, :red], [:blue, :blue]], "$Result" => :ready}, %{}, 5}

    {bindings, _, _} = expected
    assert bindings["$Pairs"] == [[:red, :red], [:blue, :blue]]
    assert bindings["$Result"] == :ready
  end

  example compiled_bodies_retain_primitives_and_propagated_constraints() do
    {:atomic, _} =
      evaluate_source(~S"""
      @machine_primitive_probe #{super => object}.

      machine_primitive_probe >> select
      | _Self Map Value |
      map_get Map amount Value,
      > Value 0,
      dif Value 2.

      vm_set_class machine_primitive_instance machine_primitive_probe.
      """)

    branch = %AL.Branch{id: Examples.Support.branch()}

    assert {:atomic, {:ok, store, 3}} =
             :mnesia.transaction(fn ->
               {:ok, _, id} =
                 AL.Dispatch.target(:machine_primitive_instance, :select, branch)

               AL.JAM.run(
                 id,
                 [:machine_primitive_instance, %{amount: 1}, {:"$var", "Value"}],
                 %{},
                 branch,
                 100
               )
             end)

    assert AL.Var.subst({:"$var", "Value"}, store) == 1

    {:atomic, {bindings, _, _}} =
      evaluate_source(~S"""
      findall Value Values {
        select machine_primitive_instance #{amount => Value} Value,
        member [-1, 1, 2, 3] Value
      }.
      """)

    assert bindings["$Values"] == [1, 3]
  end

  example map_reads_keep_enumeration_and_ground_checks() do
    {:atomic, {bindings, _, _}} =
      evaluate_source(~S"""
      @machine_map_probe #{super => object}.

      machine_map_probe >> checked
      | _Self Row Value |
      var Value,
      map_get Row value Value,
      ground Value,
      > Value 0,
      dif Value 2.

      machine_map_probe >> entry
      | _Self Map Key Value |
      map_get Map Key Value.

      vm_set_class machine_map_instance machine_map_probe.
      findall Value Values {
        member [-1, 1, 2, 3] Input,
        checked machine_map_instance #{value => Input} Value
      }.
      findall [Key, Value] Entries {
        entry machine_map_instance #{a => 1, b => 2} Key Value
      }.
      """)

    assert bindings["$Values"] == [1, 3]
    assert Enum.sort(bindings["$Entries"]) == [[:a, 1], [:b, 2]]
    bindings
  end

  example compiled_conditionals_commit_only_their_condition_choices() do
    {:atomic, _} =
      evaluate_source(~S"""
      @machine_control_probe #{super => object}.

      machine_control_probe >> nested
      | Self Result |
      {member [red, blue] Color, not {= Color green}} ->
        {{= Kind first} ; {= Kind second}, = Result [Color, Kind]}
        ; = Result otherwise.

      machine_control_probe >> outer
      | Self Result |
      {nested Self Result} ; {= Result outside}.

      machine_control_probe >> failed_then
      | _Self Result |
      {= Result committed} -> fail ; = Result otherwise.

      machine_control_probe >> restored_else
      | _Self Result |
      {= Local bound, fail} -> = Result wrong ; {var Local, = Result restored}.

      machine_control_probe >> nested_commit
      | _Self Result |
      {member [a, b] A} ->
        {{member [c, d] B} -> = Result [A, B] ; = Result inner_else}
        ; = Result outer_else.

      vm_set_class machine_control_instance machine_control_probe.
      """)

    {:atomic, {bindings, _, state}} =
      evaluate_source(~S"""
      findall Result Results {outer machine_control_instance Result}.
      findall Result Failed {failed_then machine_control_instance Result}.
      restored_else machine_control_instance Restored.
      findall Result Nested {nested_commit machine_control_instance Result}.
      """)

    expected = {bindings, state.reductions}

    assert expected ==
             {%{
                "$Results" => [[:red, :first], [:red, :second], :outside],
                "$Nested" => [[:a, :c]],
                "$Failed" => [],
                "$Restored" => :restored
              }, 8}

    {bindings, _} = expected
    assert bindings["$Results"] == [[:red, :first], [:red, :second], :outside]
    assert bindings["$Failed"] == []
    assert bindings["$Restored"] == :restored
    assert bindings["$Nested"] == [[:a, :c]]
    bindings
  end

  example compiled_branches_keep_send_sites_and_callee_cuts_separate() do
    {:atomic, _} =
      evaluate_source(~S"""
      @machine_branch_probe #{super => object}.

      machine_branch_probe >> choose
      | Self Result |
      {left Self Result} ; {right Self Result}.

      machine_branch_probe >> left
      | _Self red |
      cut.

      machine_branch_probe >> left
      | _Self discarded |.

      machine_branch_probe >> right
      | _Self blue |.

      vm_set_class machine_branch_instance machine_branch_probe.
      """)

    {:atomic, {bindings, _, _}} =
      evaluate_source(~S"""
      findall Result Results {choose machine_branch_instance Result}.
      """)

    assert bindings["$Results"] == [:red, :blue]
    bindings
  end

  example value_slot_reads_and_map_updates_preserve_constraints_and_fallbacks() do
    source = ~S"""
    @machine_value_probe #{super => object}.

    machine_value_probe >> read
    | _Self Object Key Value |
    slot Object Key Value.

    machine_value_probe >> update
    | _Self Map Key Value Updated |
    vm_map_put Map Key Value Updated.

    vm_set_class machine_value_instance machine_value_probe.
    vm_set_slot machine_value_instance stored durable.
    read machine_value_instance machine_value_instance stored Durable.
    findall [Key, Value] Entries {
      read machine_value_instance #{a => 1, b => 2} Key Value
    }.
    dif Selected red.
    read machine_value_instance #{chosen => blue} chosen Selected.
    update machine_value_instance #{kept => 1} added Shared Updated.
    = Shared bound.
    not {update machine_value_instance [] key value _}.
    not {read machine_value_instance #{a => 1} missing _}.
    """

    {:atomic, {bindings, _, _}} = evaluate_source(source)
    expected = bindings

    assert Map.update!(expected, "$Entries", &Enum.sort/1) == %{
             "$_Self" => {:"$var", "_Self"},
             "$Value" => {:"$var", "Value"},
             "$Key" => {:"$var", "Key"},
             "$Updated" => %{added: :bound, kept: 1},
             "$Map" => {:"$var", "Map"},
             "$Entries" => [[:a, 1], [:b, 2]],
             "$Selected" => :blue,
             "$Object" => {:"$var", "Object"},
             "$Shared" => :bound,
             "$Durable" => :durable
           }

    assert expected["$Durable"] == :durable
    assert Enum.sort(expected["$Entries"]) == [[:a, 1], [:b, 2]]
    assert expected["$Selected"] == :blue
    assert expected["$Updated"] == %{kept: 1, added: :bound}
  end

  example compiled_collections_preserve_duplicates_isolation_and_copied_constraints() do
    source = ~S"""
    @machine_collection_probe #{super => object}.

    machine_collection_probe >> gather
    | _Self Values Empty Nested Constrained |
    findall [X, X] Values {member [red, red, blue] X},
    var X,
    findall Hidden Empty {= Hidden local, fail},
    var Hidden,
    findall Inner Nested {
      member [a, b] Item,
      findall Part Inner {member [Item, Item] Part}
    },
    findall [Open, Open] Constrained {dif Open red, member [a, b] _Tag}.

    machine_collection_probe >> committed
    | _Self Values |
    findall X Values {{member [first, discarded] X} -> pass ; = X otherwise}.

    vm_set_class machine_collection_instance machine_collection_probe.
    gather machine_collection_instance Values Empty Nested [[A, A], [B, B]].
    = A blue.
    var B.
    not {= B red}.
    = B green.
    committed machine_collection_instance Committed.
    """

    {:atomic, {bindings, _, _}} = evaluate_source(source)
    expected = bindings

    assert expected == %{
             "$_Self" => {:"$var", "_Self"},
             "$Values" => [[:red, :red], [:red, :red], [:blue, :blue]],
             "$X" => {:"$var", "X"},
             "$Inner" => {:"$var", "Inner"},
             "$Part" => {:"$var", "Part"},
             "$Item" => {:"$var", "Item"},
             "$A" => :blue,
             "$B" => :green,
             "$Open" => {:"$var", "Open"},
             "$Empty" => [],
             "$Nested" => [[:a, :a], [:b, :b]],
             "$Committed" => [:first],
             "$Constrained" => {:"$var", "Constrained"},
             "$_Tag" => {:"$var", "_Tag"},
             "$Hidden" => {:"$var", "Hidden"}
           }

    assert expected["$Values"] == [[:red, :red], [:red, :red], [:blue, :blue]]
    assert expected["$Empty"] == []
    assert expected["$Nested"] == [[:a, :a], [:b, :b]]
    assert expected["$Committed"] == [:first]
  end

  example collection_yields_preserve_earlier_answers_and_execute_effects_once() do
    source = ~S"""
    @machine_collection_effect_probe #{super => object, ivars => [#{name => seen}]}.

    machine_collection_effect_probe >> gather
    | Self Values |
    findall X Values {
      {= X first} ; {
        member [second, third] X,
        get Self seen Seen,
        set_slot Self seen [X . Seen]
      }
    }.

    vm_set_class machine_collection_effect_instance machine_collection_effect_probe.
    set_slot machine_collection_effect_instance seen [].
    gather machine_collection_effect_instance Values.
    get machine_collection_effect_instance seen Seen.
    """

    {:atomic, {bindings, _, _}} = evaluate_source(source)
    expected = bindings

    assert expected == %{
             "$Self" => {:"$var", "Self"},
             "$Values" => [:first, :second, :third],
             "$X" => {:"$var", "X"},
             "$Seen" => [:third, :second]
           }

    assert expected["$Values"] == [:first, :second, :third]
    assert expected["$Seen"] == [:third, :second]
  end

  example register_locals_keep_aliases_arithmetic_constraints_and_alternatives() do
    source = ~S"""
    @machine_register_probe #{super => object}.

    machine_register_probe >> build
    | Self Input Result |
    = Local Input,
    dif Local red,
    map_get #{value => Local} value Read,
    vm_map_put #{} saved Read Map,
    not {= Local red},
    = Result Map.

    machine_register_probe >> calculate
    | _Self Input Result |
    = Local (+ Input 1),
    = Result Local.

    machine_register_probe >> collect
    | _Self Result |
    findall X Local {{= X a} ; {= X b, not {= X c}}},
    = Result Local.

    vm_set_class machine_register_instance machine_register_probe.
    findall Result Results {
      member [red, blue, green] Input,
      build machine_register_instance Input Result
    }.
    build machine_register_instance Open Shared.
    = Open blue.
    = Shared #{saved => blue}.
    calculate machine_register_instance 4 Sum.
    collect machine_register_instance Collected.
    """

    {:atomic, {bindings, _, _}} = evaluate_source(source)
    expected = bindings

    assert expected == %{
             "$Self" => {:"$var", "Self"},
             "$_Self" => {:"$var", "_Self"},
             "$X" => {:"$var", "X"},
             "$Result" => {:"$var", "Result"},
             "$Input" => {:"$var", "Input"},
             "$Map" => {:"$var", "Map"},
             "$Sum" => 5,
             "$Local" => {:"$var", "Local"},
             "$Read" => {:"$var", "Read"},
             "$Open" => :blue,
             "$Results" => [%{saved: :blue}, %{saved: :green}],
             "$Shared" => %{saved: :blue},
             "$Collected" => [:a, :b]
           }

    assert expected["$Results"] == [%{saved: :blue}, %{saved: :green}]
    assert expected["$Sum"] == 5
    assert expected["$Collected"] == [:a, :b]
  end

  example register_results_follow_overrides_and_method_edits() do
    source = ~S"""
    @machine_projection_probe #{super => object}.

    machine_projection_probe >> value
    | _Self Value |
    map_get #{value => original} value Value.

    machine_projection_probe >> relay
    | Self Result |
    value Self Local,
    = Result [Local, Local].

    vm_set_class machine_projection_instance machine_projection_probe.
    relay machine_projection_instance Before.
    defmethod machine_projection_probe value [_Self, added] {}.
    findall Result Results {relay machine_projection_instance Result}.
    """

    {:atomic, {bindings, _, _}} = evaluate_source(source)
    expected = bindings

    assert expected == %{
             "$Self" => {:"$var", "Self"},
             "$_Self" => {:"$var", "_Self"},
             "$Value" => {:"$var", "Value"},
             "$Result" => {:"$var", "Result"},
             "$Local" => {:"$var", "Local"},
             "$Results" => [[:original, :original], [:added, :added]],
             "$Before" => [:original, :original]
           }

    assert expected["$Before"] == [:original, :original]
    assert expected["$Results"] == [[:original, :original], [:added, :added]]
  end

  example recursive_register_returns_preserve_base_cases_and_shared_outputs() do
    source = ~S"""
    @machine_return_register_probe #{super => object}.

    machine_return_register_probe >> build
    | _Self [] #{} |.

    machine_return_register_probe >> build
    | Self [Key . Keys] Result |
    build Self Keys Rest,
    vm_map_put Rest Key Key Result.

    machine_return_register_probe >> relay
    | Self Keys Result |
    build Self Keys Local,
    = Result Local.

    machine_return_register_probe >> shared
    | _Self Input Output |
    = Input [Output],
    = Output blue.

    machine_return_register_probe >> share
    | Self Input Result |
    shared Self Input Local,
    = Result Local.

    vm_set_class machine_return_register_instance machine_return_register_probe.
    relay machine_return_register_instance [a, b, c] Result.
    findall Map Maps {
      member [[], [a], [b, c]] Keys,
      relay machine_return_register_instance Keys Map
    }.
    share machine_return_register_instance Input Shared.
    """

    {:atomic, {bindings, _, _}} = evaluate_source(source)
    expected = bindings

    assert expected == %{
             "$Self" => {:"$var", "Self"},
             "$_Self" => {:"$var", "_Self"},
             "$Key" => {:"$var", "Key"},
             "$Keys" => {:"$var", "Keys"},
             "$Rest" => {:"$var", "Rest"},
             "$Output" => {:"$var", "Output"},
             "$Result" => %{c: :c, a: :a, b: :b},
             "$Input" => [:blue],
             "$Local" => {:"$var", "Local"},
             "$Shared" => :blue,
             "$Maps" => [%{}, %{a: :a}, %{c: :c, b: :b}]
           }

    assert expected["$Result"] == %{a: :a, b: :b, c: :c}
    assert expected["$Maps"] == [%{}, %{a: :a}, %{b: :b, c: :c}]
    assert expected["$Input"] == [:blue]
    assert expected["$Shared"] == :blue
  end

  example register_return_frames_survive_yields_suspensions_and_constraints() do
    source = ~S"""
    @machine_return_handoff_probe #{super => object, ivars => [#{name => seen}]}.

    machine_return_handoff_probe >> produce
    | Self Output |
    = Output [Open, Open, Ready],
    dif Open red,
    park Self Open Ready,
    = Open blue,
    get Self seen Seen,
    set_slot Self seen [once . Seen].

    machine_return_handoff_probe >> park
    | _Self Open Ready |
    freeze Open {= Ready awake}.

    machine_return_handoff_probe >> relay
    | Self Output |
    produce Self Local,
    = Output Local.

    vm_set_class machine_return_handoff_instance machine_return_handoff_probe.
    set_slot machine_return_handoff_instance seen [].
    findall Result Results {
      member [first, second] _Tag,
      relay machine_return_handoff_instance Result
    }.
    get machine_return_handoff_instance seen Seen.
    """

    {:atomic, {bindings, _, _}} = evaluate_source(source)
    expected = bindings

    assert expected == %{
             "$Self" => {:"$var", "Self"},
             "$_Self" => {:"$var", "_Self"},
             "$Output" => {:"$var", "Output"},
             "$Ready" => {:"$var", "Ready"},
             "$Seen" => [:once, :once],
             "$Local" => {:"$var", "Local"},
             "$Open" => {:"$var", "Open"},
             "$Results" => [[:blue, :blue, :awake], [:blue, :blue, :awake]]
           }

    assert expected["$Results"] == [[:blue, :blue, :awake], [:blue, :blue, :awake]]
    assert expected["$Seen"] == [:once, :once]
  end

  example receiver_shapes_preserve_bound_keys_classes_and_nested_payloads() do
    source = ~S"""
    @jam_shape_probe #{super => object}.
    @jam_shape_value #{super => value}.

    jam_shape_probe >> inspect_value
    | _Self Receiver Result |
    read_payload Receiver Result.

    jam_shape_value >> read_payload
    | #{class => jam_shape_value, payload => [#{inside => Value}]} Value |.

    jam_shape_probe >> repeat
    | _Self Receiver Result |
    same_payload Receiver #{class => jam_shape_value, payload => [#{inside => blue}]} Result.

    jam_shape_value >> same_payload
    | Self Self Result |
    get Self payload Result.

    jam_shape_probe >> walk
    | _Self [] [] |.

    jam_shape_probe >> walk
    | Self [Receiver . Tail] [Value . Values] |
    inspect_value Self Receiver Value,
    walk Self Tail Values.

    list >> jam_shape_tail
    | [] |.

    list >> jam_shape_tail
    | [#{inside => Item} . Tail] |
    dif Item forbidden,
    jam_shape_tail Tail.

    jam_shape_probe >> tails
    | _Self Items |
    jam_shape_tail Items.

    vm_set_class jam_shape_instance jam_shape_probe.
    = Receiver #{ClassKey => Class, PayloadKey => [#{InnerKey => Value}]}.
    = ClassKey class.
    = Class jam_shape_value.
    = PayloadKey payload.
    = InnerKey inside.
    dif Value red.
    inspect_value jam_shape_instance Receiver Read.
    = Read blue.
    repeat jam_shape_instance Receiver Repeated.
    tails jam_shape_instance [#{InnerKey => Value}, #{inside => allowed}].
    not {tails jam_shape_instance [#{inside => forbidden}]}.
    findall Results All {
      member [first, second] Item,
      walk jam_shape_instance [#{class => jam_shape_value, payload => [#{inside => Item}]}, Receiver] Results
    }.
    """

    {:atomic, {bindings, _, _}} = evaluate_source(source)
    expected = bindings

    assert expected == %{
             "$Self" => {:"$var", "Self"},
             "$Class" => :jam_shape_value,
             "$_Self" => {:"$var", "_Self"},
             "$Value" => :blue,
             "$Values" => {:"$var", "Values"},
             "$Result" => {:"$var", "Result"},
             "$Receiver" => %{class: :jam_shape_value, payload: [%{inside: :blue}]},
             "$Items" => {:"$var", "Items"},
             "$Tail" => {:"$var", "Tail"},
             "$Item" => {:"$var", "Item"},
             "$All" => [[:first, :blue], [:second, :blue]],
             "$Read" => :blue,
             "$Repeated" => [%{inside: :blue}],
             "$ClassKey" => :class,
             "$PayloadKey" => :payload,
             "$InnerKey" => :inside
           }

    assert expected["$Read"] == :blue
    assert expected["$Repeated"] == [%{inside: :blue}]
    assert expected["$All"] == [[:first, :blue], [:second, :blue]]
  end

  example selective_field_reads_preserve_keys_aliases_constraints_and_enumeration() do
    source = ~S"""
    @jam_field_probe #{super => object}.

    jam_field_probe >> read
    | _Self Read ViaSlot Bound Entries Collapsed Wild Open |
    = Map #{Key => #{Inner => Value}, spare => [Other]},
    = Key wanted,
    = Inner nested,
    dif Value forbidden,
    map_get Map wanted Read,
    slot Map wanted ViaSlot,
    = Read #{nested => blue},
    = ViaSlot #{nested => blue},
    map_get Map wanted #{nested => blue},
    slot Map wanted #{nested => blue},
    = Bound Value,
    = Other unrelated,
    not {map_get Map missing _},
    findall [Name, Found] Entries {map_get Map Name Found},
    = Collision #{KeyA => first, KeyB => second},
    = KeyA same,
    = KeyB same,
    map_get Collision same Collapsed,
    map_get #{key => _} key Wild,
    = Wild chosen,
    map_get Open wanted red,
    = Open #{wanted => red}.

    vm_set_class jam_field_instance jam_field_probe.
    read jam_field_instance Read ViaSlot Bound Entries Collapsed Wild Open.
    """

    {:atomic, {bindings, _, _}} = evaluate_source(source)
    expected = bindings

    assert expected == %{
             "$_Self" => {:"$var", "_Self"},
             "$Value" => {:"$var", "Value"},
             "$Name" => {:"$var", "Name"},
             "$Key" => {:"$var", "Key"},
             "$Other" => {:"$var", "Other"},
             "$Inner" => {:"$var", "Inner"},
             "$Map" => {:"$var", "Map"},
             "$Entries" => [[:wanted, %{nested: :blue}], [:spare, [:unrelated]]],
             "$Read" => %{nested: :blue},
             "$Open" => %{wanted: :red},
             "$Wild" => :chosen,
             "$ViaSlot" => %{nested: :blue},
             "$Bound" => :blue,
             "$Found" => {:"$var", "Found"},
             "$Collapsed" => :second,
             "$Collision" => {:"$var", "Collision"},
             "$KeyA" => {:"$var", "KeyA"},
             "$KeyB" => {:"$var", "KeyB"}
           }

    assert expected["$Read"] == %{nested: :blue}
    assert expected["$ViaSlot"] == %{nested: :blue}
    assert expected["$Bound"] == :blue

    assert Enum.sort(expected["$Entries"]) == [
             [:spare, [:unrelated]],
             [:wanted, %{nested: :blue}]
           ]

    assert expected["$Wild"] == :chosen
    assert expected["$Open"] == %{wanted: :red}
  end

  example forwarded_arguments_preserve_open_aliases_modes_and_alternatives() do
    source = ~S"""
    @jam_forward_probe #{super => object}.

    jam_forward_probe >> identity
    | _Self Value Value |.

    jam_forward_probe >> choose
    | _Self Value Value |.

    jam_forward_probe >> choose
    | _Self _Value alternative |.

    jam_forward_probe >> pair
    | Self Input Result |
    identity Self Input Local,
    = Result [Local, Local].

    jam_forward_probe >> reversed
    | Self Input Result |
    identity Self Local Input,
    = Result Local.

    jam_forward_probe >> fresh_pair
    | Self Result |
    identity Self Left Right,
    = Left blue,
    = Result [Left, Right].

    jam_forward_probe >> wildcard
    | Self Result |
    identity Self _ Local,
    = Local chosen,
    = Result Local.

    jam_forward_probe >> alternatives
    | Self Input Result |
    choose Self Input Local,
    = Result [Local].

    vm_set_class jam_forward_instance jam_forward_probe.
    dif Input red.
    pair jam_forward_instance Input Pair.
    not {= Input red}.
    = Input blue.
    reversed jam_forward_instance [a, b] Reversed.
    fresh_pair jam_forward_instance Fresh.
    wildcard jam_forward_instance Wild.
    findall Result Results {alternatives jam_forward_instance original Result}.
    """

    {:atomic, {bindings, _, _}} = evaluate_source(source)
    expected = bindings

    assert expected == %{
             "$Self" => {:"$var", "Self"},
             "$_Self" => {:"$var", "_Self"},
             "$Value" => {:"$var", "Value"},
             "$Left" => {:"$var", "Left"},
             "$Right" => {:"$var", "Right"},
             "$_Value" => {:"$var", "_Value"},
             "$Reversed" => [:a, :b],
             "$Result" => {:"$var", "Result"},
             "$Input" => :blue,
             "$Local" => {:"$var", "Local"},
             "$Results" => [[:original], [:alternative]],
             "$Pair" => [:blue, :blue],
             "$Fresh" => [:blue, :blue],
             "$Wild" => :chosen
           }

    assert expected["$Pair"] == [:blue, :blue]
    assert expected["$Reversed"] == [:a, :b]
    assert expected["$Fresh"] == [:blue, :blue]
    assert expected["$Wild"] == :chosen
    assert expected["$Results"] == [[:original], [:alternative]]
  end

  example callable_sites_track_captured_bindings_and_nested_dependencies() do
    source = ~S"""
    @jam_callable_probe #{super => object}.

    jam_callable_probe >> invoke
    | _Self Head Body Result |
    call Head Body [Result].

    jam_callable_probe >> exercise
    | Self Before After Different Results |
    = Head [Output],
    = Body {= Output Capture},
    = Capture [Nested],
    invoke Self Head Body Warm,
    invoke Self Head Body WarmAgain,
    invoke Self Head Body Before,
    = Nested blue,
    invoke Self Head Body After,
    = Warm [first],
    = WarmAgain [second],
    = Before [third],
    invoke Self Head {= Output different} Different,
    = ChoiceBody {= Output Pick},
    pick Self Pick,
    invoke Self Head ChoiceBody One,
    invoke Self Head ChoiceBody Two,
    invoke Self Head ChoiceBody Three,
    dif Pick red,
    = Results [One, Two, Three].

    jam_callable_probe >> pick
    | _Self red |.

    jam_callable_probe >> pick
    | _Self green |.

    vm_set_class jam_callable_instance jam_callable_probe.
    findall [Before, After, Different, Results] All {
      exercise jam_callable_instance Before After Different Results
    }.
    """

    {:atomic, {bindings, _, _}} = evaluate_source(source)
    expected = bindings["$All"]

    assert expected == [[[:third], [:blue], :different, [:green, :green, :green]]]

    assert expected == [
             [[:third], [:blue], :different, [:green, :green, :green]]
           ]
  end

  example arithmetic_register_results_preserve_open_inputs_aliases_and_choices() do
    source = ~S"""
    @jam_arithmetic_probe #{super => object}.

    jam_arithmetic_probe >> calculate
    | _Self Input Result |
    = Local (- Input 1),
    = (+ Local 2) Result.

    jam_arithmetic_probe >> nested
    | _Self Input Result |
    = Local (+ (* Input 3) (- 2)),
    = Result [Local, Local].

    jam_arithmetic_probe >> choose
    | _Self 3 |.

    jam_arithmetic_probe >> choose
    | _Self 7 |.

    jam_arithmetic_probe >> selected
    | Self Result |
    choose Self Input,
    calculate Self Input Result,
    dif Result 4.

    vm_set_class jam_arithmetic_instance jam_arithmetic_probe.
    calculate jam_arithmetic_instance 5 Ground.
    calculate jam_arithmetic_instance Open Delayed.
    = Open 9.
    = Alias Constrained.
    > Constrained 3.
    calculate jam_arithmetic_instance 3 Alias.
    nested jam_arithmetic_instance 4 Repeated.
    findall Result Results {selected jam_arithmetic_instance Result}.
    not {calculate jam_arithmetic_instance 3 9}.
    """

    {:atomic, {bindings, _, _}} = evaluate_source(source)
    expected = Map.take(bindings, ["$Ground", "$Delayed", "$Alias", "$Repeated", "$Results"])

    assert expected == %{
             "$Results" => ~c"\b",
             "$Repeated" => ~c"\n\n",
             "$Alias" => 4,
             "$Delayed" => 10,
             "$Ground" => 6
           }

    assert expected == %{
             "$Ground" => 6,
             "$Delayed" => 10,
             "$Alias" => 4,
             "$Repeated" => [10, 10],
             "$Results" => [8]
           }
  end

  example cut_boundaries_survive_mutations_collections_and_nested_callables() do
    {:atomic, _} =
      evaluate_source(~S"""
      @machine_cut_boundary #{super => object}.

      machine_cut_boundary >> first
      | Self Color |
      member [red, blue] Color,
      vm_set_slot Self picked Color,
      cut.

      machine_cut_boundary >> first
      | _Self discarded |.

      machine_cut_boundary >> reject
      | Self Color |
      first Self Color,
      cut,
      fail.

      machine_cut_boundary >> reject
      | _Self unwanted |.

      machine_cut_boundary >> gather
      | _Self Colors |
      findall Color Colors {member [red, blue] Color, cut}.

      vm_set_class machine_cut_boundary_instance machine_cut_boundary.
      """)

    {:atomic, {bindings, _, _}} =
      evaluate_source(~S"""
      findall [Outer, Color] Pairs {
        member [one, two] Outer,
        first machine_cut_boundary_instance Color
      }.
      findall X Failed {reject machine_cut_boundary_instance X}.
      lambda [Color] First {member [red, blue] Color, cut}.
      findall [Outer, Color] Called {
        member [one, two] Outer,
        run First [Color]
      }.
      findall Colors Nested {
        member [one, two] _,
        gather machine_cut_boundary_instance Colors
      }.
      findall X After {
        first machine_cut_boundary_instance _,
        member [left, right] X
      }.
      """)

    expected = Map.take(bindings, ["$Pairs", "$Failed", "$Called", "$Nested", "$After"])

    assert expected == %{
             "$Pairs" => [[:one, :red], [:two, :red]],
             "$After" => [:left, :right],
             "$Called" => [[:one, :red], [:two, :red]],
             "$Nested" => [[:red], [:red]],
             "$Failed" => []
           }

    assert expected == %{
             "$Pairs" => [[:one, :red], [:two, :red]],
             "$Failed" => [],
             "$Called" => [[:one, :red], [:two, :red]],
             "$Nested" => [[:red], [:red]],
             "$After" => [:left, :right]
           }
  end

  example delayed_cuts_are_local_to_the_frozen_goal() do
    {:atomic, _} =
      evaluate_source(~S"""
      @machine_wake_probe #{super => object}.

      machine_wake_probe >> arm
      | _Self Trigger Color |
      freeze Trigger {member [red, blue] Color, cut}.

      machine_wake_probe >> fire
      | _Self Trigger Tail |
      = Trigger go,
      member [left, right] Tail.

      machine_wake_probe >> fire
      | _Self Trigger discarded |
      = Trigger stop.

      vm_set_class machine_wake_instance machine_wake_probe.
      """)

    {:atomic, {bindings, _, _}} =
      evaluate_source(~S"""
      findall [Outer, Color, Tail] Answers {
        member [one, two] Outer,
        arm machine_wake_instance Trigger Color,
        = Trigger Alias,
        fire machine_wake_instance Alias Tail
      }.
      """)

    expected = bindings["$Answers"]

    assert expected == [
             [:one, :red, :left],
             [:one, :red, :right],
             [:one, :red, :discarded],
             [:two, :red, :left],
             [:two, :red, :right],
             [:two, :red, :discarded]
           ]

    assert expected == [
             [:one, :red, :left],
             [:one, :red, :right],
             [:one, :red, :discarded],
             [:two, :red, :left],
             [:two, :red, :right],
             [:two, :red, :discarded]
           ]
  end

  example pending_continuations_survive_head_bindings_mutations_and_backtracking() do
    {:atomic, _} =
      evaluate_source(~S"""
      @machine_pending_probe #{super => object}.

      machine_pending_probe >> bind
      | Self red Other |
      vm_set_slot Self picked red,
      = Other left.

      machine_pending_probe >> bind
      | Self blue Other |
      vm_set_slot Self picked blue,
      = Other right.

      vm_set_class machine_pending_instance machine_pending_probe.
      """)

    {:atomic, {bindings, _, _}} =
      evaluate_source(~S"""
      freeze Guard {= Guard ready}.
      findall [Color, Side, First, Second] Answers {
        freeze Color {= First Color},
        freeze Side {= Second Side},
        = Side Alias,
        bind machine_pending_instance Color Alias
      }.
      freeze Trigger {= Next go}.
      freeze Next {= Result awake}.
      = Trigger now.
      = Guard ready.
      """)

    expected = Map.take(bindings, ["$Answers", "$Result"])

    assert expected == %{
             "$Result" => :awake,
             "$Answers" => [[:red, :left, :red, :left], [:blue, :right, :blue, :right]]
           }

    assert expected == %{
             "$Answers" => [[:red, :left, :red, :left], [:blue, :right, :blue, :right]],
             "$Result" => :awake
           }
  end

  example suspended_relations_enter_jam_and_restore_each_alternative() do
    {:atomic, _} =
      evaluate_source(~S"""
      @machine_parked_relation #{super => value}.

      machine_parked_relation >> text
      | _Self "red" |.

      machine_parked_relation >> text
      | _Self "blue" |.

      machine_parked_relation >> mapping
      | _Self #{first => red, second => blue} |.
      """)

    {:atomic, {bindings, _, _}} =
      evaluate_source(~S"""
      findall [Word, Text, Codes] Words {
        atom_string Word Text,
        string_codes Text Codes,
        = Text Alias,
        text #{class => machine_parked_relation} Alias
      }.
      findall [Key, Value] Entries {
        map_get Map Key Value,
        mapping #{class => machine_parked_relation} Map
      }.
      atom_string Guard GuardText.
      findall Text Rejected {
        atom_string Word Text,
        dif Word red,
        text #{class => machine_parked_relation} Text
      }.
      = GuardText "ready".
      """)

    expected = Map.take(bindings, ["$Words", "$Entries", "$Rejected", "$Guard"])

    assert expected == %{
             "$Entries" => [[:first, :red], [:second, :blue]],
             "$Guard" => :ready,
             "$Rejected" => ["blue"],
             "$Words" => [[:red, "red", ~c"red"], [:blue, "blue", ~c"blue"]]
           }

    assert expected == %{
             "$Words" => [[:red, "red", ~c"red"], [:blue, "blue", ~c"blue"]],
             "$Entries" => [[:first, :red], [:second, :blue]],
             "$Rejected" => ["blue"],
             "$Guard" => :ready
           }
  end

  example delayed_mixed_bodies_run_only_when_woken() do
    {:atomic, _} =
      evaluate_source(~S"""
      @machine_mixed_wake #{super => value}.

      machine_mixed_wake >> choose
      | _Self Color Copy Goals |
      freeze Trigger {
        member [red, blue] Color,
        copy_term Color Copy Goals,
        == Color Copy
      },
      = Trigger ready.

      machine_mixed_wake >> capture
      | _Self Result |
      freeze Trigger {
        dif Value excluded,
        copy_term Value Copy Goals,
        = Result [Copy, Goals]
      },
      = Trigger ready.
      """)

    {:atomic, {bindings, _, _}} =
      evaluate_source(~S"""
      findall [Color, Copy, Goals] Answers {
        choose #{class => machine_mixed_wake} Color Copy Goals
      }.
      capture #{class => machine_mixed_wake} [Copy, Goals].
      variant Goals [(dif Copy excluded)].
      not {choose #{class => machine_mixed_wake} red blue _}.
      """)

    expected = bindings["$Answers"]

    assert expected == [[:red, :red, []], [:blue, :blue, []]]
    assert expected == [[:red, :red, []], [:blue, :blue, []]]
  end

  defp evaluate_source(source),
    do: AL.eval_source(source, %AL.Branch{id: Examples.Support.branch()})

  defp machine_answers({:ok, store, _steps}, choices, branch),
    do: [AL.Var.subst({:"$var", "Pair"}, store) | remaining_answers(choices, branch)]

  defp machine_answers({:answers, store, alternatives, _steps}, choices, branch),
    do: [
      AL.Var.subst({:"$var", "Pair"}, store) | remaining_answers(alternatives ++ choices, branch)
    ]

  defp remaining_answers([], _branch), do: []

  defp remaining_answers([choice | rest], branch),
    do: machine_answers(AL.JAM.resume(choice, branch, 1000), rest, branch)
end
