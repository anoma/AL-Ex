defmodule AL.JAM.PrimitiveOutputTest do
  use ExUnit.Case, async: false

  setup do
    branch = AL.Branch.fork()
    on_exit(fn -> AL.Branch.discard(branch) end)

    assert {:atomic, _} =
             AL.eval_source(
               ~S"""
               @primitive_output_probe
               #{super => value}.
               primitive_output_probe >> text
               | _Self Codes Result |
               string_codes Text Codes,
               atom_string Atom Text,
               = Result Atom.
               primitive_output_probe >> codes
               | _Self Atom Result |
               atom_string Atom Text,
               string_codes Text Codes,
               = Result Codes.
               primitive_output_probe >> delayed
               | _Self Codes Result |
               string_codes Text Codes,
               = Result Text,
               = Codes [97].
               primitive_output_probe >> delayed_conflict
               | _Self Codes Result |
               string_codes Text Codes,
               = Result Text,
               = Text "b",
               = Codes [97].
               primitive_output_probe >> pairs
               | _Self Map Result |
               map_pairs Map Pairs,
               = Result Pairs.
               primitive_output_probe >> map
               | _Self Pairs Result |
               map_pairs Map Pairs,
               = Result Map.
               """,
               branch
             )

    %{branch: branch}
  end

  test "conversion chains preserve both directions and Unicode", %{branch: branch} do
    assert {:atomic, {bindings, _, _}} =
             AL.eval_source(
               ~S"""
               text #{class => primitive_output_probe} [955, 128512] Atom,
               codes #{class => primitive_output_probe} Atom Codes.
               """,
               branch
             )

    assert bindings[:"$Atom"] == :"λ😀"
    assert bindings[:"$Codes"] == [955, 128_512]
  end

  test "suspended outputs preserve aliases and later bindings", %{branch: branch} do
    assert {:atomic, {bindings, _, _}} =
             AL.eval_source(
               ~S"""
               delayed #{class => primitive_output_probe} Codes Text.
               """,
               branch
             )

    assert bindings[:"$Codes"] == [97]
    assert bindings[:"$Text"] == "a"

    assert {:aborted, _} =
             AL.eval_source(
               ~S"""
               delayed_conflict #{class => primitive_output_probe} Codes Text.
               """,
               branch
             )
  end

  test "maps retain shared values and pair ordering", %{branch: branch} do
    assert {:atomic, {bindings, _, _}} =
             AL.eval_source(
               ~S"""
               map #{class => primitive_output_probe} [[b, Value], [a, Value]] Map,
               pairs #{class => primitive_output_probe} Map Pairs,
               = Value bound.
               """,
               branch
             )

    assert bindings[:"$Pairs"] == [[:a, :bound], [:b, :bound]]
    assert bindings[:"$Map"] == %{a: :bound, b: :bound}
  end

  test "invalid codepoints and duplicate map keys still fail", %{branch: branch} do
    for program <- [
          ~S"text #{class => primitive_output_probe} [55296] Result.",
          ~S"map #{class => primitive_output_probe} [[a, 1], [a, 2]] Result."
        ] do
      assert {:aborted, _} = AL.eval_source(program, branch)
    end
  end

  test "constrained outputs and alternative answer order are preserved", %{branch: branch} do
    assert {:aborted, _} =
             AL.eval_source(
               ~S"""
               dif Output a,
               text #{class => primitive_output_probe} [97] Output.
               """,
               branch
             )

    assert {:atomic, {bindings, _, _}} =
             AL.eval_source(
               ~S"""
               findall Output Answers {
                 text #{class => primitive_output_probe} [97] Output ;
                 text #{class => primitive_output_probe} [98] Output
               }.
               """,
               branch
             )

    assert bindings[:"$Answers"] == [:a, :b]
  end
end
