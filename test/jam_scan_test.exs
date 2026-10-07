Code.require_file("../bench/support/scan_region.exs", __DIR__)

defmodule AL.JAM.ScanTest do
  use ExUnit.Case, async: false
  alias AL.JAM.IR.Scan

  setup do
    branch = AL.Branch.fork()
    on_exit(fn -> AL.Branch.discard(branch) end)
    %{branch: branch}
  end

  defp compile(branch, receiver \\ %{class: :al_grammar}, selector \\ :symbol) do
    {:atomic, plan} = :mnesia.transaction(fn -> Scan.compile(receiver, selector, branch) end)
    plan
  end

  defp valid?(plan, branch) do
    {:atomic, valid} = :mnesia.transaction(fn -> Scan.valid?(plan, branch) end)
    valid
  end

  defp execute(plan, input), do: Bench.ScanRegion.run(plan, input)

  defp source(text, branch), do: assert({:atomic, _} = AL.eval_source(text, branch))

  defp install(branch) do
    source(
      ~S"""
      @scan_probe #{super => value}.
      scan_probe >> read_prefix
      | Self Input Rest Value |
      not {var Input},
      element Self Input After First,
      gather Self After Rest element More,
      atom_string Value Text,
      string_codes Text [First . More].
      scan_probe >> read_prefix
      | _Self Input _Rest _Value |
      var Input.
      scan_probe >> element
      | _Self Input Rest Code |
      = Input [Code . Rest],
      dif Code 32,
      dif Code 46.
      scan_probe >> gather
      | Self Input Rest Predicate [Value . Values] |
      send Self Predicate [Input, After, Value],
      dif Input After,
      gather Self After Rest Predicate Values.
      scan_probe >> gather
      | _Self Rest Rest _Predicate [] |.
      """,
      branch
    )
  end

  test "the loaded provider chain yields a scan with ordered answers", %{branch: branch} do
    plan = compile(branch)
    assert %Scan{} = plan
    assert valid?(plan, branch)

    assert {:ok,
            [
              [:point, ~c"\n"],
              [:poin, ~c"t\n"],
              [:poi, ~c"nt\n"],
              [:po, ~c"int\n"],
              [:p, ~c"oint\n"]
            ]} = execute(plan, ~c"point\n")

    assert :fallback = execute(plan, ~c"Point\n")
    assert :fallback = execute(plan, ~c"123\n")
    refute valid?(plan, AL.Branch.main())
  end

  test "renamed relations and changed character tests are inferred from their bodies", %{
    branch: branch
  } do
    install(branch)
    plan = compile(branch, %{class: :scan_probe}, :read_prefix)
    assert %Scan{reject: []} = plan

    assert {:ok, [[:abc, ~c".rest"], [:ab, ~c"c.rest"], [:a, ~c"bc.rest"]]} =
             execute(plan, ~c"abc.rest")

    source(
      ~S"""
      scan_probe >> element
      | _Self Input Rest Code |
      = Input [Code . Rest],
      dif Code 32,
      dif Code 98.
      """,
      branch
    )

    refute valid?(plan, branch)
    changed = compile(branch, %{class: :scan_probe}, :read_prefix)
    assert {:ok, [[:a, ~c"bc.rest"]]} = execute(changed, ~c"abc.rest")
  end

  test "putting the stop clause first rejects longest-first composition", %{branch: branch} do
    install(branch)

    source(
      ~S"""
      scan_probe >> gather
      | _Self Rest Rest _Predicate [] |.
      scan_probe >> gather
      | Self Input Rest Predicate [Value . Values] |
      send Self Predicate [Input, After, Value],
      dif Input After,
      gather Self After Rest Predicate Values.
      """,
      branch
    )

    assert is_nil(compile(branch, %{class: :scan_probe}, :read_prefix))
  end

  test "duplicated answers and changed recursive arguments are not silently collapsed", %{
    branch: branch
  } do
    install(branch)

    source(
      ~S"""
      scan_probe >> gather
      | Self Input Rest Predicate [Value . Values] |
      send Self Predicate [Input, After, Value],
      dif Input After,
      gather Self Input Rest Predicate Values.
      scan_probe >> gather
      | _Self Rest Rest _Predicate [] |.
      """,
      branch
    )

    assert is_nil(compile(branch, %{class: :scan_probe}, :read_prefix))
    install(branch)

    source(
      ~S"""
      defmethod scan_probe gather [_Self, Rest, Rest, _Predicate, []] {}.
      """,
      branch
    )

    assert is_nil(compile(branch, %{class: :scan_probe}, :read_prefix))
  end

  test "a changed consuming output is rejected", %{branch: branch} do
    install(branch)

    source(
      ~S"""
      scan_probe >> element
      | _Self Input Rest Result |
      = Input [Code . Rest],
      dif Code 32,
      dif Code 46,
      = Result 65.
      """,
      branch
    )

    assert is_nil(compile(branch, %{class: :scan_probe}, :read_prefix))
  end

  test "effects before classification invalidate the proof", %{branch: branch} do
    plan = compile(branch)

    source(
      ~S"""
      variable_syntax >> variable_start
      | Self Input Rest |
      format 'classification',
      code Self Input Rest Code,
      >= Code 65,
      <= Code 90.
      """,
      branch
    )

    refute valid?(plan, branch)
    assert is_nil(compile(branch))
  end

  test "helper edits invalidate the whole composition", %{branch: branch} do
    plan = compile(branch)

    source(
      ~S"""
      syntax >> unless
      | _Self Rest Rest _Pattern |.
      """,
      branch
    )

    refute valid?(plan, branch)
    assert is_nil(compile(branch))
  end

  test "provider edits invalidate the composition", %{branch: branch} do
    plan = compile(branch)

    source(
      ~S"""
      variable_syntax >> symbol
      | _Self Input Input replacement |.
      """,
      branch
    )

    refute valid?(plan, branch)
    assert is_nil(compile(branch))
  end

  test "an atom classifier acquiring a collection class invalidates rejection", %{branch: branch} do
    plan = compile(branch)

    source(
      ~S"""
      vm_set_class variable_start list.
      """,
      branch
    )

    refute valid?(plan, branch)
    assert is_nil(compile(branch))
  end

  test "replacing the dispatch target invalidates an existing provider chain", %{branch: branch} do
    plan = compile(branch)

    source(
      ~S"""
      al_grammar >> symbol
      | _Self Input Input replacement |.
      """,
      branch
    )

    refute valid?(plan, branch)
    assert is_nil(compile(branch))
  end

  test "integrated execution agrees with traced fallback", %{
    branch: branch
  } do
    for input <- [~c"point\n", ~c"p_42 ", ~c"pλ ", ~c"Point ", ~c"123 ", ~c" "] do
      program = [
        %AL.Goal.Findall{
          template: [{:"$var", "Value"}, {:"$var", "Rest"}],
          result: {:"$var", "Answers"},
          condition: [
            %AL.Goal.Send{
              object: %{class: :al_grammar},
              method: :symbol,
              args: [input, {:"$var", "Rest"}, {:"$var", "Value"}]
            }
          ]
        }
      ]

      assert {:atomic, {expected, _, _}} = AL.eval(program, nil, branch, trace: [:goals])
      assert {:atomic, {^expected, _, _}} = AL.eval(program, nil, branch)
    end

    source(
      ~S"""
      symbol #{class => al_grammar} [112, 111, 105, 110, 116, 10] [116, 10] poin.
      """,
      branch
    )
  end

  test "open input keeps the generative relation", %{branch: branch} do
    assert {:atomic, {bindings, _, _}} =
             AL.eval_source(
               ~S"""
               symbol #{class => al_grammar} Input [] point.
               """,
               branch
             )

    assert bindings["$Input"] == ~c"point"
  end

  test "bound and constrained results retain prefix order and aliases", %{branch: branch} do
    for {output, constraints} <- [
          {:get, []},
          {:ge, []},
          {:missing, []},
          {{:"$var", "Value"}, [%AL.Goal.Dif{a: {:"$var", "Value"}, b: :get}]},
          {{:"$var", "Value"}, [%AL.Goal.Eq{a: {:"$var", "Value"}, b: {:"$var", "Alias"}}]},
          {{:"$var", "Rest"}, []},
          {%AL.Goal.Compound{name: :var, args: [{:"$var", "Rest"}]}, []}
        ] do
      condition =
        constraints ++
          [
            %AL.Goal.Send{
              object: %{class: :al_grammar},
              method: :symbol,
              args: [~c"get ", {:"$var", "Rest"}, output]
            }
          ]

      program = [
        %AL.Goal.Findall{
          template: [output, {:"$var", "Rest"}],
          result: {:"$var", "Answers"},
          condition: condition
        }
      ]

      assert {:atomic, {expected, _, _}} = AL.eval(program, nil, branch, trace: [:goals])
      assert {:atomic, {^expected, _, _}} = AL.eval(program, nil, branch)
    end
  end

  test "bound results enter the region while shared rest variables fall back", %{branch: branch} do
    assert {:atomic, :ok} =
             :mnesia.transaction(fn ->
               AL.ResolutionCache.with_transaction_cache(fn ->
                 receiver = %{class: :al_grammar}
                 {:ok, _, id} = AL.Dispatch.target(receiver, :symbol, branch)
                 callee = AL.JAM.Compiler.fetch_method(id, branch)

                 enter = fn value ->
                   AL.JAM.Scan.enter(
                     callee,
                     receiver,
                     :symbol,
                     {:constant, [~c"get ", {:"$var", "Rest"}, value]},
                     {},
                     %{},
                     branch,
                     100_000
                   )
                 end

                 assert {:region, _, _, _, _, _, _} = enter.(:get)
                 assert :fallback = enter.({:"$var", "Rest"})

                 assert :fallback =
                          enter.(%AL.Goal.Compound{name: :var, args: [{:"$var", "Rest"}]})

                 :ok
               end)
             end)
  end

  test "source changes after an answer use the saved generic suffix on retry", %{branch: branch} do
    {:ok, mutation} =
      AL.Syntax.parse("defmethod syntax unless [_Self, Tail, [999 . Tail], _Pattern] {}.")

    program = [
      %AL.Goal.Findall{
        template: [{:"$var", "Value"}, {:"$var", "Rest"}],
        result: {:"$var", "Answers"},
        condition: [
          %AL.Goal.Send{
            object: %{class: :al_grammar},
            method: :symbol,
            args: [~c"point\n", {:"$var", "Rest"}, {:"$var", "Value"}]
          },
          %AL.Goal.Implies{
            condition: [%AL.Goal.Eq{a: {:"$var", "Value"}, b: :point}],
            then: mutation.program ++ [%AL.Goal.Fail{}],
            otherwise: [%AL.Goal.Pass{}]
          }
        ]
      }
    ]

    reference_branch = AL.Branch.fork(:tip, branch)

    reference =
      try do
        assert {:atomic, {bindings, _, _}} =
                 AL.eval(program, nil, reference_branch, trace: [:goals])

        bindings["$Answers"]
      after
        AL.Branch.discard(reference_branch)
      end

    assert {:atomic, {bindings, _, _}} = AL.eval(program, nil, branch)
    assert bindings["$Answers"] == reference

    assert bindings["$Answers"] ==
             Enum.flat_map(
               [
                 [:poin, ~c"t\n"],
                 [:poi, ~c"nt\n"],
                 [:po, ~c"int\n"],
                 [:p, ~c"oint\n"]
               ],
               fn [atom, rest] ->
                 [
                   [atom, rest],
                   [atom, [999 | rest]]
                 ]
               end
             )
  end

  test "a missing selector is unsupported", %{branch: branch} do
    assert is_nil(compile(branch, %{class: :al_grammar}, :missing_scan_selector))
  end

  test "a classifier edit after an answer can activate its later provider alternative", %{
    branch: branch
  } do
    {:ok, mutation} =
      AL.Syntax.parse("""
      variable_syntax >> variable_start
      | _Self _Input _Rest |
      (fail).
      """)

    program = [
      %AL.Goal.Findall{
        template: [{:"$var", "Value"}, {:"$var", "Rest"}],
        result: {:"$var", "Answers"},
        condition: [
          %AL.Goal.Send{
            object: %{class: :al_grammar},
            method: :symbol,
            args: [~c"Point\n", {:"$var", "Rest"}, {:"$var", "Value"}]
          },
          %AL.Goal.Implies{
            condition: [
              %AL.Goal.Eq{
                a: {:"$var", "Value"},
                b: %AL.Goal.Compound{name: :var, args: ["Point"]}
              }
            ],
            then: mutation.program ++ [%AL.Goal.Fail{}],
            otherwise: [%AL.Goal.Atom{term: {:"$var", "Value"}}]
          }
        ]
      }
    ]

    for opts <- [[], [trace: [:goals]]] do
      isolated = AL.Branch.fork(:tip, branch)

      try do
        assert {:atomic, {bindings, _, _}} = AL.eval(program, nil, isolated, opts)

        assert bindings["$Answers"] == [
                 [:Point, ~c"\n"],
                 [:Poin, ~c"t\n"],
                 [:Poi, ~c"nt\n"],
                 [:Po, ~c"int\n"],
                 [:P, ~c"oint\n"]
               ]
      after
        AL.Branch.discard(isolated)
      end
    end
  end
end
