defmodule AL.JAM.BinaryGrammarTest do
  use ExUnit.Case, async: false

  setup do
    branch = AL.TestBranch.fork()
    on_exit(fn -> AL.Branch.discard(branch) end)
    %{branch: branch}
  end

  defp source(text, branch), do: assert(%AL{result: {:atomic, _}} = AL.run(text, branch))

  test "binary grammar answers agree with semantic tracing", %{
    branch: branch
  } do
    for input <- ["point\n", "p_42 ", "pλ ", "Point ", "123 ", " "] do
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
      symbol #{class => al_grammar} "point\n" "t\n" poin.
      """,
      branch
    )
  end

  test "open input keeps the generative relation", %{branch: branch} do
    assert %AL{result: {:atomic, {bindings, _, _}}} =
             AL.run(
               ~S"""
               symbol #{class => al_grammar} Input "" point.
               """,
               branch
             )

    assert bindings["$Input"] == "point"
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
              args: ["get ", {:"$var", "Rest"}, output]
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

  test "source changes after an answer affect the remaining search", %{branch: branch} do
    {:ok, mutation} =
      AL.Syntax.parse(
        ~S|defmethod syntax unless [_Self, Tail, Output, _Pattern] {vm_text_concat "ϧ" Tail Output}.|
      )

    program = [
      %AL.Goal.Findall{
        template: [{:"$var", "Value"}, {:"$var", "Rest"}],
        result: {:"$var", "Answers"},
        condition: [
          %AL.Goal.Send{
            object: %{class: :al_grammar},
            method: :symbol,
            args: ["point\n", {:"$var", "Rest"}, {:"$var", "Value"}]
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
                 [:poin, "t\n"],
                 [:poi, "nt\n"],
                 [:po, "int\n"],
                 [:p, "oint\n"]
               ],
               fn [atom, rest] ->
                 [
                   [atom, rest],
                   [atom, "ϧ" <> rest]
                 ]
               end
             )
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
            args: ["Point\n", {:"$var", "Rest"}, {:"$var", "Value"}]
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
                 [:Point, "\n"],
                 [:Poin, "t\n"],
                 [:Poi, "nt\n"],
                 [:Po, "int\n"],
                 [:P, "oint\n"]
               ]
      after
        AL.Branch.discard(isolated)
      end
    end
  end
end
