defmodule AL.FormatTest do
  use ExUnit.Case, async: false

  setup do
    branch = AL.TestBranch.fork()
    on_exit(fn -> AL.Branch.discard(branch) end)
    %{branch: branch}
  end

  test "the formatting DCG renders strings and literal directives", %{branch: branch} do
    assert {:atomic, {bindings, _, _}} =
             AL.run(
               ~S"""
               format "Hello ~a — ~~ ~%~a!" ["world", "done"] Text.
               format "" [] Empty.
               """,
               branch: branch
             )

    assert bindings["$Text"] == "Hello world — ~ \ndone!"
    assert bindings["$Empty"] == ""
  end

  test "formatting an object uses its print_object method", %{branch: branch} do
    assert {:atomic, {bindings, _, _}} =
             AL.run(
               ~S"""
               @formatted_value #{super => object}.
               formatted_value >> print_object
               | Self "widget" |.
               new formatted_value Value.
               format "[~a]" [Value] Text.
               """,
               branch: branch
             )

    assert bindings["$Text"] == "[widget]"
  end

  test "print_object returns text for default objects and values", %{branch: branch} do
    assert {:atomic, {bindings, _, _}} =
             AL.run(
               ~S"""
               new object Object,
               print_object Object IdText,
               atom_string Object IdText,
               print_object "hello" StringText,
               print_object 42 NumberText,
               print_object [a, b] ListText.
               """,
               branch: branch
             )

    assert is_binary(bindings["$IdText"])
    assert bindings["$StringText"] == "hello"
    assert bindings["$NumberText"] == "42"
    assert bindings["$ListText"] == "[a, b]"
  end

  test "format requires a string from print_object", %{branch: branch} do
    assert {:aborted, _} =
             AL.run(
               ~S"""
               @invalid_printer #{super => object}.
               invalid_printer >> print_object
               | _Self 42 |.
               new invalid_printer Object.
               format "~a" [Object] Text.
               """,
               branch: branch
             )
  end

  test "the DCG renders structured AL terms", %{branch: branch} do
    assert {:atomic, {bindings, _, _}} =
             AL.run(
               ~S"""
               new object #{name => on} Value.
               format "~a ~a ~a ~a" [Value, -42, [a, b], {f a, g b}] Text.
               format "~a" [#{k => [a, b]}] MapText.
               """,
               branch: branch
             )

    assert bindings["$Text"] == "on -42 [a, b] {f a, g b}"
    assert bindings["$MapText"] == ~S"#{k => [a, b]}"
  end

  test "malformed templates and argument mismatches fail", %{branch: branch} do
    for source <- [
          ~S(format "~q" [] Text.),
          ~S(format "~" [] Text.),
          ~S(format "~a" [] Text.),
          ~S(format "plain" [unused] Text.)
        ] do
      assert {:aborted, _} = AL.run(source, branch)
    end
  end

  test "the formatting grammar can override directives", %{branch: branch} do
    assert {:atomic, {bindings, _, _}} =
             AL.run(
               ~S"""
               @custom_format #{super => format_syntax, metaclass => grammar}.
               defrule custom_format (template [Value . Args] [91 . Output] Tail)
                 ["~w", where [Value, Output, More] {
                   string_codes Value Codes,
                   concat Codes [93 . More] Output
                 }, template Args More Tail].
               defrule custom_format (template Args Output Tail) [next].
               parse custom_format (template ["first", "second"] Codes []) "~w ~a",
               string_codes Text Codes.
               """,
               branch: branch
             )

    assert bindings["$Text"] == "[first] second"
  end
end
