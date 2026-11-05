defmodule AL.DefinitionOriginTest do
  use ExUnit.Case, async: false

  setup do
    branch = AL.TestBranch.fork()
    on_exit(fn -> AL.Branch.discard(branch) end)
    assert %AL{result: {:atomic, _}} = AL.run("@origin_owner \#{super => object}.", branch)
    %{branch: branch}
  end

  for {name, body} <- [
        {"tail delegation", "vm_oapply origin_install [Owner, Selector, Head, Body]"},
        {"method send", "install_definition Owner Selector Head Body"},
        {"block call", "run {vm_oapply origin_install [Owner, Selector, Head, Body]}"},
        {"collection in a helper",
         "findall yes _ {vm_oapply origin_install [Owner, Selector, Head, Body]}"},
        {"bounded collection in a helper",
         "findnsols 1 yes _ {vm_oapply origin_install [Owner, Selector, Head, Body]}"},
        {"backtracking in a helper",
         "fail ; vm_oapply origin_install [Owner, Selector, Head, Body]"}
      ],
      trace <- [[], [:domino, :vm]] do
    @body body
    @trace trace
    test "retains exact source through #{name} with trace #{inspect(trace)}", %{branch: branch} do
      replace_definition(branch, :defmethod, "[Owner, Selector, Head, Body]", @body)

      source =
        "origin_owner >> first\n| Self first |.\norigin_owner >> second\n| Self second |.\n" <>
          "defmethod origin_owner second [Self, extra] {pass}.\n"

      assert %AL{result: {:atomic, _}} = AL.run(source, branch, trace: @trace)

      rows = AL.Source.method_source_rows(:origin_owner, branch)
      assert ["first", 0, "origin_owner >> first\n| Self first |", 2, 1, :retained, nil] in rows

      assert ["second", 0, "origin_owner >> second\n| Self second |", 2, 3, :retained, nil] in rows
      assert Enum.any?(rows, &match?(["second", 1, _, _, _, :decompiled, _], &1))
    end
  end

  for trace <- [[], [:domino, :vm]] do
    @trace trace
    test "delayed helpers retain distinct origins with trace #{inspect(trace)}", %{
      branch: branch
    } do
      replace_definition(
        branch,
        :defclass,
        "[Name, Meta, Super, Ivars, Categories]",
        "freeze Name {vm_oapply origin_install [Name, Meta, Super, Ivars, Categories]}"
      )

      source = ~S"""
      @First #{super => object}.
      @Second #{super => object}.
      = Second origin_second.
      = First origin_first.
      """

      assert %AL{result: {:atomic, {_, _, state}}} = AL.run(source, branch, trace: @trace)

      {:atomic, spans} = :mnesia.transaction(fn -> AL.SourceStore.spans(branch) end)

      for {target, text} <- [
            {:origin_first, "@First \#{super => object}"},
            {:origin_second, "@Second \#{super => object}"}
          ] do
        assert {:source_span, _, _, :defclass, range, %{class: ^target}} =
                 Enum.find(spans, fn
                   {:source_span, _, tx, :defclass, _, %{class: ^target}} -> tx == state.tx_id
                   _ -> false
                 end)

        assert {:ok, ^text} = AL.Syntax.slice(source, range)
      end
    end
  end

  for {name, body} <- [
        {"missing", "pass"},
        {"duplicate",
         "vm_oapply origin_install [Owner, Selector, Head, Body], vm_oapply origin_install [Owner, Selector, Head, Body]"}
      ] do
    @body body
    @name name
    test "rejects #{@name} definition writes and rolls them back", %{branch: branch} do
      replace_definition(branch, :defmethod, "[Owner, Selector, Head, Body]", @body)

      assert %AL{result: {:aborted, %AL.Source.ProvenanceError{reason: reason}}} =
               AL.run("origin_owner >> invalid_origin\n| Self |.", branch)

      case @name do
        "missing" -> assert reason == :missing_anchor
        "duplicate" -> assert {:multiple_anchors, [_, _]} = reason
      end

      refute Enum.any?(
               AL.Source.method_source_rows(:origin_owner, branch),
               &match?(["invalid_origin" | _], &1)
             )
    end
  end

  defp replace_definition(branch, method, head, body) do
    source = """
    clause #{method} OriginalHead OriginalBody,
    vm_set_class origin_install behaviour,
    vm_set_oapply origin_install OriginalHead OriginalBody,
    vm_set_method class install_definition origin_install,
    vm_retract_oapply #{method} OriginalHead,
    vm_set_class origin_delegate behaviour,
    vm_set_oapply origin_delegate #{head} {#{body}},
    vm_set_oapply #{method} #{head} {vm_oapply origin_delegate #{head}}.
    """

    assert %AL{result: {:atomic, _}} = AL.run(source, branch)
  end
end
