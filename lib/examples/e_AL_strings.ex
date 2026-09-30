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
        ~AL"""
        class "hello" C.
        isa "hello" value.
        not (isa "hello" number).
        """
      end

    assert Map.get(bindings, :"$C") == :string
  end

  example a_string_receives_string_methods() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        string >> paired_example
        | Self [Self, Self] |.

        paired_example "hi" Pair.
        """
      end

    assert Map.get(bindings, :"$Pair") == ["hi", "hi"]
  end

  example string_codes_relates_a_string_to_its_codepoints() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        string_codes "héllo" Codes.
        string_codes Built [104, 105].
        """
      end

    assert Map.get(bindings, :"$Codes") == [104, 233, 108, 108, 111]
    assert Map.get(bindings, :"$Built") == "hi"
  end

  example atom_string_relates_atoms_and_strings() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        atom_string Atom "hello".
        atom_string world Text.
        atom_string world "world".
        """
      end

    assert Map.get(bindings, :"$Atom") == :hello
    assert Map.get(bindings, :"$Text") == "world"
  end

  example atom_string_waits_for_a_known_side() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        atom_string Atom Text.
        = Text "ready".
        """
      end

    assert Map.get(bindings, :"$Atom") == :ready
  end

  example atom_recognizes_atoms_without_binding_variables() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        atom hello.
        not (atom "hello").
        not (atom 42).
        not (atom Unknown).
        """
      end

    :ok
  end

  example string_codes_binds_open_codes_from_a_string() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        string_codes "hi" [104, Second].
        """
      end

    assert Map.get(bindings, :"$Second") == 105
  end

  example string_codes_rejects_what_is_not_text() do
    {:aborted, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        string_codes 42 _Codes.
        """
      end

    {:aborted, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        string_codes _String [55296].
        """
      end

    {:aborted, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        string_codes "hi" [104].
        """
      end

    :ok
  end

  example string_codes_waits_until_either_side_is_known() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        string_codes FromCodes [104 . Rest].
        string_codes FromString LaterCodes.
        = Rest [105].
        = FromString "ok".
        """
      end

    assert Map.get(bindings, :"$FromCodes") == "hi"
    assert Map.get(bindings, :"$LaterCodes") == [111, 107]
  end

  example string_codes_follows_constraints_on_its_codes() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        findall String Strings {
          string_codes String [Code],
          >= Code 97,
          <= Code 99,
          label Code
        }.
        """
      end

    assert Map.get(bindings, :"$Strings") == ["a", "b", "c"]
  end

  example concat_joins_strings() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        concat "rela" "tion" Whole.
        concat "rela" Rest "relation".
        """
      end

    assert Map.get(bindings, :"$Whole") == "relation"
    assert Map.get(bindings, :"$Rest") == "tion"
  end

  example concat_enumerates_every_split_of_a_pinned_string() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        findall [Front, Back] Splits {isa Front string, concat Front Back "abc"}.
        """
      end

    assert Map.get(bindings, :"$Splits") == [
             ["", "abc"],
             ["a", "bc"],
             ["ab", "c"],
             ["abc", ""]
           ]
  end

  example an_unpinned_receiver_also_reads_concat_as_a_list() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        findall [Front, Back] Splits (concat Front Back "ab").
        """
      end

    assert Enum.sort(Map.get(bindings, :"$Splits")) ==
             Enum.sort([[[], "ab"], ["", "ab"], ["a", "b"], ["ab", ""]])
  end

  example split_separates_a_string_at_each_separator() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        findall Parts Answers (split "a,b,,c" "," Parts).
        split "plain" "," Unsplit.
        split "" "," Empty.
        """
      end

    assert Map.get(bindings, :"$Answers") == [["a", "b", "", "c"]]
    assert Map.get(bindings, :"$Unsplit") == ["plain"]
    assert Map.get(bindings, :"$Empty") == [""]
  end

  example split_joins_parts_with_a_separator() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        split Joined ", " ["one", "two", "three"].
        """
      end

    assert Map.get(bindings, :"$Joined") == "one, two, three"
  end

  example split_cuts_at_the_leftmost_separator() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        findall Parts Answers (split "a:::b" "::" Parts).
        """
      end

    assert Map.get(bindings, :"$Answers") == [["a", ":b"]]
  end

  example split_rejects_parts_that_contain_the_separator() do
    {:aborted, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        split _Joined "," ["a,b", "c"].
        """
      end

    {:aborted, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        split "abc" "" _Parts.
        """
      end

    :ok
  end

  example split_works_on_any_list() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        split [1, 0, 2, 3, 0, 4] [0] Parts.
        """
      end

    assert Map.get(bindings, :"$Parts") == [[1], [2, 3], [4]]
  end

  example length_counts_codepoints() do
    {:atomic, {bindings, _constraints, _state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        length "héllo" N.
        """
      end

    assert Map.get(bindings, :"$N") == 5
  end
end
