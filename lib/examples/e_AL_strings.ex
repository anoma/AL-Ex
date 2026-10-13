defmodule Examples.ALStrings do
  @moduledoc """
  I provide string examples: a string is a value of class `:string`, so it
  dispatches like numbers, lists, and maps.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example a_string_is_a_string_value() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        class("hello", c)
        isa("hello", :value)
        not [isa("hello", :number)]
      end

    assert Map.get(bindings, :"$c") == :string
  end

  example a_string_receives_string_methods() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        defmethod(:string, :paired_example, [self, [self, self]])
        paired_example("hi", pair)
      end

    assert Map.get(bindings, :"$pair") == ["hi", "hi"]
  end

  example string_codes_relates_a_string_to_its_codepoints() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        string_codes("héllo", codes)
        string_codes(built, [104, 105])
      end

    assert Map.get(bindings, :"$codes") == [104, 233, 108, 108, 111]
    assert Map.get(bindings, :"$built") == "hi"
  end

  example string_codes_binds_open_codes_from_a_string() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        string_codes("hi", [104, second])
      end

    assert Map.get(bindings, :"$second") == 105
  end

  example string_codes_rejects_what_is_not_text() do
    {:aborted, _} =
      run branch: Examples.Support.branch() do
        string_codes(42, _codes)
      end

    {:aborted, _} =
      run branch: Examples.Support.branch() do
        string_codes(_string, [0xD800])
      end

    {:aborted, _} =
      run branch: Examples.Support.branch() do
        string_codes("hi", [104])
      end

    :ok
  end

  example string_codes_waits_until_either_side_is_known() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        string_codes(from_codes, [104 | rest])
        string_codes(from_string, later_codes)
        rest = [105]
        from_string = "ok"
      end

    assert Map.get(bindings, :"$from_codes") == "hi"
    assert Map.get(bindings, :"$later_codes") == [111, 107]
  end

  example string_codes_follows_constraints_on_its_codes() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        findall(string, strings) do
          string_codes(string, [code])
          code >= 97
          code <= 99
          label(code)
        end
      end

    assert Map.get(bindings, :"$strings") == ["a", "b", "c"]
  end

  example concat_joins_strings() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        concat("rela", "tion", whole)
        concat("rela", rest, "relation")
      end

    assert Map.get(bindings, :"$whole") == "relation"
    assert Map.get(bindings, :"$rest") == "tion"
  end

  example concat_enumerates_every_split_of_a_pinned_string() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        findall([front, back], splits) do
          isa(front, :string)
          concat(front, back, "abc")
        end
      end

    assert Map.get(bindings, :"$splits") == [
             ["", "abc"],
             ["a", "bc"],
             ["ab", "c"],
             ["abc", ""]
           ]
  end

  example an_unpinned_receiver_also_reads_concat_as_a_list() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        findall([front, back], splits) do
          concat(front, back, "ab")
        end
      end

    assert Enum.sort(Map.get(bindings, :"$splits")) ==
             Enum.sort([[[], "ab"], ["", "ab"], ["a", "b"], ["ab", ""]])
  end

  example split_separates_a_string_at_each_separator() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        findall(parts, answers) do
          split("a,b,,c", ",", parts)
        end

        split("plain", ",", unsplit)
        split("", ",", empty)
      end

    assert Map.get(bindings, :"$answers") == [["a", "b", "", "c"]]
    assert Map.get(bindings, :"$unsplit") == ["plain"]
    assert Map.get(bindings, :"$empty") == [""]
  end

  example split_joins_parts_with_a_separator() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        split(joined, ", ", ["one", "two", "three"])
      end

    assert Map.get(bindings, :"$joined") == "one, two, three"
  end

  example split_cuts_at_the_leftmost_separator() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        findall(parts, answers) do
          split("a:::b", "::", parts)
        end
      end

    assert Map.get(bindings, :"$answers") == [["a", ":b"]]
  end

  example split_rejects_parts_that_contain_the_separator() do
    {:aborted, _} =
      run branch: Examples.Support.branch() do
        split(_joined, ",", ["a,b", "c"])
      end

    {:aborted, _} =
      run branch: Examples.Support.branch() do
        split("abc", "", _parts)
      end

    :ok
  end

  example split_works_on_any_list() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        split([1, 0, 2, 3, 0, 4], [0], parts)
      end

    assert Map.get(bindings, :"$parts") == [[1], [2, 3], [4]]
  end

  example length_counts_codepoints() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        length("héllo", n)
      end

    assert Map.get(bindings, :"$n") == 5
  end
end
