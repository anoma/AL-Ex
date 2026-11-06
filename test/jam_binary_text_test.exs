defmodule AL.JAM.BinaryTextTest do
  use ExUnit.Case, async: true

  setup do
    branch = AL.TestBranch.fork()
    on_exit(fn -> AL.Branch.discard(branch) end)
    %{branch: branch}
  end

  test "UTF-8 consumption and construction preserve codepoints and binary tails", %{
    branch: branch
  } do
    for trace <- [[], [:goals], [:domino], [:vm]] do
      assert %AL{result: {:atomic, {bindings, _, _}}} =
               AL.run(
                 ~S|uncons "λ😀" First Rest, uncons Rest Second "", isa Built string, uncons Built First Rest.|,
                 branch,
                 trace: trace
               )

      assert bindings["$First"] == "λ"
      assert bindings["$Second"] == "😀"
      assert bindings["$Rest"] == "😀"
      assert bindings["$Built"] == "λ😀"
    end
  end

  test "uncons waits for an open character and remainder", %{branch: branch} do
    for trace <- [[], [:goals]] do
      assert %AL{result: {:atomic, {bindings, %{}, _}}} =
               AL.run(
                 ~S"""
                 isa Text string,
                 uncons Text Char Rest,
                 = Char "λ", = Rest "😀".
                 """,
                 branch,
                 trace: trace
               )

      assert bindings["$Text"] == "λ😀"
    end
  end

  test "fresh codepoint outputs agree with relational execution and delayed input", %{
    branch: branch
  } do
    assert %AL{result: {:atomic, _}} =
             AL.run(
               ~S"""
               @binary_output_probe #{super => value}.
               binary_output_probe >> split
               | _Self Input Result |
               vm_text_code Input Code Rest,
               = Result [Code, Rest].
               binary_output_probe >> same
               | _Self Input Result |
               vm_text_code Input Value Value,
               = Result Value.
               """,
               branch
             )

    for trace <- [[], [:goals], [:domino], [:vm]],
        {input, expected} <- [{"λ😀", [955, "😀"]}, {<<97, 255>>, [97, <<255>>]}] do
      assert %AL{result: {:atomic, {bindings, %{}, _}}} =
               AL.run(~S|split #{class => binary_output_probe} Input Result.|, branch,
                 trace: trace,
                 bindings: %{"Input" => input}
               )

      assert bindings["$Result"] == expected
    end

    for query <- [
          ~S|split #{class => binary_output_probe} Input Result, = Input "λ😀".|,
          ~S|split #{class => binary_output_probe} Input Result, = Result [955, "😀"].|
        ] do
      assert %AL{result: {:atomic, {bindings, %{}, _}}} = AL.run(query, branch)
      assert bindings["$Input"] == "λ😀"
      assert bindings["$Result"] == [955, "😀"]
    end

    for input <- ["", <<255>>] do
      assert %AL{result: {:aborted, _}} =
               AL.run(~S|split #{class => binary_output_probe} Input Result.|, branch,
                 bindings: %{"Input" => input}
               )
    end

    assert %AL{result: {:aborted, _}} =
             AL.run(~S|same #{class => binary_output_probe} "a" Result.|, branch)

    assert %AL{result: {:aborted, _}} =
             AL.run(
               ~S|dif Result [97, ""], split #{class => binary_output_probe} "a" Result.|,
               branch
             )

    assert %AL{result: {:atomic, {_, _, state}}} =
             AL.run(~S|split #{class => binary_output_probe} "λ😀" Result.|, branch, trace: [:vm])

    assert Enum.any?(state.trace.events, fn
             %{
               payload:
                 {:instruction,
                  %{
                    instruction:
                      {:primitive_into, :vm_text_code,
                       [_, {:destination, code}, {:destination, rest}]},
                    registers: slots
                  }}
             } ->
               elem(slots, code) == nil and elem(slots, rest) == nil

             _ ->
               false
           end)
  end

  test "unknown text waits for codepoints and tails and observes their constraints", %{
    branch: branch
  } do
    assert %AL{result: {:atomic, {bindings, _, _}}} =
             AL.run(
               ~S"""
               vm_text_code Text Code Tail,
               vm_text_concat Text "!" Result,
               >= Code 955, <= Code 955,
               = Tail "😀".
               findall Word Words {vm_text_code Word C "", in_domain C [97, 98, 99], label C}.
               """,
               branch
             )

    assert bindings["$Result"] == "λ😀!"
    assert bindings["$Words"] == ["a", "b", "c"]
  end

  test "fresh binary remainders preserve relational modes", %{branch: branch} do
    assert %AL{result: {:atomic, _}} =
             AL.run(
               ~S"""
               @text_output_probe #{super => value}.
               text_output_probe >> prefix
               | _Self Prefix Input Result |
               vm_text_concat Prefix Rest Input,
               = Result Rest.
               text_output_probe >> repeated
               | _Self Input Result |
               vm_text_concat Part Part Input,
               = Result Part.
               """,
               branch
             )

    for trace <- [[], [:goals], [:domino], [:vm]] do
      assert %AL{result: {:atomic, {bindings, %{}, _}}} =
               AL.run(
                 ~S"""
                 prefix #{class => text_output_probe} "λ" Input Rest,
                 = Input "λ😀",
                 repeated #{class => text_output_probe} "λλ" Half,
                 findall Suffix Suffixes {prefix #{class => text_output_probe} Prefix "ab" Suffix}.
                 """,
                 branch,
                 trace: trace
               )

      assert bindings["$Rest"] == "😀"
      assert bindings["$Half"] == "λ"
      assert bindings["$Suffixes"] == ["ab", "b", ""]

      assert %AL{result: {:aborted, _}} =
               AL.run(
                 ~S|dif Result "😀", prefix #{class => text_output_probe} "λ" "λ😀" Result.|,
                 branch,
                 trace: trace
               )
    end

    assert %AL{result: {:atomic, {bindings, %{}, state}}} =
             AL.run(
               ~S|prefix #{class => text_output_probe} "λ" "λ😀" Rest.|,
               branch,
               trace: [:vm]
             )

    assert bindings["$Rest"] == "😀"

    assert Enum.any?(state.trace.events, fn
             %{
               payload:
                 {:instruction,
                  %{
                    instruction:
                      {:primitive_into, :vm_text_concat, [_, {:destination, index}, _]},
                    registers: slots
                  }}
             } ->
               elem(slots, index) == nil

             _ ->
               false
           end)
  end

  test "enumerated concatenation splits follow UTF-8 boundaries and respect aliases", %{
    branch: branch
  } do
    assert %AL{result: {:atomic, {bindings, _, _}}} =
             AL.run(
               ~S"""
               findall [Left, Right] Splits {isa Left string, concat Left Right "λ😀"}.
               findall Half Halves {vm_text_concat Half Half "λλ"}.
               vm_text_concat "" Unknown Same, = Same "later".
               """,
               branch
             )

    assert bindings["$Splits"] == [["", "λ😀"], ["λ", "😀"], ["λ😀", ""]]
    assert bindings["$Halves"] == ["λ"]
    assert bindings["$Unknown"] == "later"
  end

  test "length counts codepoints and empty text can be constructed", %{branch: branch} do
    assert %AL{result: {:atomic, {bindings, _, _}}} =
             AL.run(~S|length "é😀" N, vm_text_length Empty 0.|, branch)

    assert bindings["$N"] == 3
    assert bindings["$Empty"] == ""
  end

  test "fragment assembly waits for open fragments and preserves UTF-8", %{branch: branch} do
    assert %AL{result: {:atomic, {bindings, _, _}}} =
             AL.run(~S|join_text ["λ", Middle . Tail] Text, = Middle "😀", = Tail ["!"].|, branch)

    assert bindings["$Text"] == "λ😀!"
  end

  test "fragment assembly preserves opaque bytes and checks the assembled result", %{
    branch: branch
  } do
    for trace <- [[], [:goals], [:domino], [:vm]] do
      assert %AL{result: {:atomic, {bindings, %{}, _}}} =
               AL.run(
                 ~S|join_text [First, Middle . Tail] Text, = Middle Bad, = Tail ["!"], join_text [First, Bad, "!"] Text.|,
                 branch,
                 bindings: %{"First" => <<195>>, "Bad" => <<169, 255>>},
                 trace: trace
               )

      assert bindings["$Text"] == <<195, 169, 255, 33>>

      assert %AL{result: {:aborted, _}} =
               AL.run(~S|join_text [Bad] "different".|, branch,
                 bindings: %{"Bad" => <<255>>},
                 trace: trace
               )

      assert %AL{result: {:aborted, _}} =
               AL.run(~S|dif Text Bad, join_text [Bad] Text.|, branch,
                 bindings: %{"Bad" => <<255>>},
                 trace: trace
               )
    end
  end

  test "invalid codepoints, malformed binaries and incompatible results fail", %{branch: branch} do
    for source <- [
          ~S|vm_text_code Text 55296 "".|,
          ~S|vm_text_code Text -1 "".|,
          ~S|vm_text_code "" Code Rest.|,
          ~S|vm_text_code "λ" 97 Rest.|,
          ~S|vm_text_code Same 97 Same.|,
          ~S|vm_text_length "λ" 2.|,
          ~S|vm_text_join ["ok", 97] Text.|,
          ~S|vm_text_join ["ok" . nope] Text.|
        ] do
      assert %AL{result: {:aborted, _}} = AL.run(source, branch)
    end

    for source <- [
          "vm_text_code Bad Code Rest.",
          "vm_text_length Bad N."
        ] do
      assert %AL{result: {:aborted, _}} =
               AL.run(source, branch, bindings: %{"Bad" => <<255>>, "Good" => "ok"})
    end
  end

  test "concatenation matches and constructs binary pieces without decoding them", %{
    branch: branch
  } do
    for trace <- [[], [:goals], [:domino], [:vm]],
        {query, inputs, result, expected} <- [
          {"vm_text_concat Left Rest Whole.", %{"Left" => "a", "Whole" => <<97, 255>>}, "$Rest",
           <<255>>},
          {"vm_text_concat Prefix Right Whole.", %{"Right" => "a", "Whole" => <<255, 97>>},
           "$Prefix", <<255>>},
          {"vm_text_concat Left Rest Whole.", %{"Left" => <<195>>, "Whole" => "é"}, "$Rest",
           <<169>>},
          {"vm_text_concat Prefix Right Whole.", %{"Right" => <<169>>, "Whole" => "é"}, "$Prefix",
           <<195>>},
          {"vm_text_concat Left Right Whole.", %{"Left" => <<195>>, "Right" => <<169>>}, "$Whole",
           "é"},
          {"vm_text_concat Left Right Whole.", %{"Left" => <<255>>, "Right" => "a"}, "$Whole",
           <<255, 97>>},
          {"vm_text_concat Left Rest Whole.", %{"Left" => <<255>>, "Whole" => <<255, 97>>},
           "$Rest", "a"},
          {"vm_text_concat Prefix Right Whole.", %{"Right" => <<255>>, "Whole" => <<97, 255>>},
           "$Prefix", "a"}
        ] do
      assert %AL{result: {:atomic, {bindings, %{}, _}}} =
               AL.run(query, branch, bindings: inputs, trace: trace)

      assert bindings[result] == expected
    end
  end

  test "binary concatenation preserves delayed inputs, constraints and exact matching", %{
    branch: branch
  } do
    assert %AL{result: {:atomic, {bindings, %{}, _}}} =
             AL.run(
               ~S"""
               vm_text_concat Bad Right Whole,
               = Right "a",
               vm_text_concat "" Bad Same,
               vm_text_concat Bad Bad Twice.
               """,
               branch,
               bindings: %{"Bad" => <<255>>}
             )

    assert bindings["$Whole"] == <<255, 97>>
    assert bindings["$Same"] == <<255>>
    assert bindings["$Twice"] == <<255, 255>>

    for {left, right, whole} <- [{<<255>>, "a", <<255, 97>>}, {<<195>>, <<169>>, "é"}] do
      assert %AL{result: {:atomic, _}} =
               AL.run("vm_text_concat Left Right Whole.", branch,
                 bindings: %{"Left" => left, "Right" => right, "Whole" => whole}
               )
    end

    for {query, inputs} <- [
          {"vm_text_concat Left Right Whole.",
           %{"Left" => "a", "Right" => <<255>>, "Whole" => <<97, 254>>}},
          {"vm_text_concat Left Rest Whole.", %{"Left" => "ab", "Whole" => "a"}},
          {"vm_text_concat Prefix Right Whole.", %{"Right" => "ab", "Whole" => "a"}},
          {"vm_text_concat Left Rest Whole.", %{"Left" => "a", "Whole" => "b"}},
          {"vm_text_concat Prefix Right Whole.", %{"Right" => "a", "Whole" => "b"}},
          {~S|dif Rest Bad, vm_text_concat "a" Rest Whole.|,
           %{"Bad" => <<255>>, "Whole" => <<97, 255>>}},
          {~S|vm_text_concat "a" Rest Whole, vm_text_code Rest Code Tail.|,
           %{"Whole" => <<97, 255>>}},
          {"vm_text_concat Left Right Whole.", %{"Left" => 97, "Right" => "a"}}
        ] do
      assert %AL{result: {:aborted, _}} = AL.run(query, branch, bindings: inputs)
    end
  end

  test "enumeration retains prefixes before an invalid codepoint", %{branch: branch} do
    for {input, expected} <- [
          {<<255>>, [["", <<255>>]]},
          {<<97, 255>>, [["", <<97, 255>>], ["a", <<255>>]]},
          {"λ" <> <<255>>, [["", "λ" <> <<255>>], ["λ", <<255>>]]}
        ] do
      assert %AL{result: {:atomic, {bindings, %{}, _}}} =
               AL.run(
                 ~S|findall [Left, Right] Splits {vm_text_concat Left Right Input}.|,
                 branch,
                 bindings: %{"Input" => input}
               )

      assert bindings["$Splits"] == expected
    end
  end
end
