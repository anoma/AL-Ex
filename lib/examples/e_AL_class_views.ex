defmodule Examples.ALClassViews do
  use ExExample
  import ExUnit.Assertions

  def rerun?(_), do: true

  example target() do
    evaluate(~S"""
    @class_view_example_meta #{super => class}.
    class_view_example_meta >> class_view
    | _Self _Builder View |
    new phlow_text #{title => "Extra", text => "Custom view", priority => 40} View.
    class_view_example_meta >> class_view
    | Self Builder View |
    call_next_method Self Builder View.
    @class_view_example_parent #{super => object}.
    class_view_example_parent >> inherited
    | _Self first |.
    class_view_example_parent >> inherited
    | _Self second |.
    @class_view_example_child
    #{super => class_view_example_parent, metaclass => class_view_example_meta}.
    class_view_example_child >> own
    | _Self original |.
    set_slot class_view_example_child comment "Example comment".
    """)

    :class_view_example_child
  end

  example views() do
    values =
      evaluate(
        ~S"""
        new phlow_views #{title => "Code", target => Target, selector => class_view} View.
        to_map View Description.
        definition_source Target Definition.
        comment_source Target Comment.
        """,
        %{"Target" => target()}
      )

    views = values["$Description"].views
    assert Enum.map(views, & &1.title) == ["Extra", "Methods", "Definition", "Comment"]
    assert Enum.all?(views, &(&1.view == "deferred" and not Map.has_key?(&1, :content)))
    assert values["$Definition"].text =~ "metaclass => class_view_example_meta"
    assert values["$Comment"].text == "Example comment"
    values["$Description"]
  end

  example filtered_sources() do
    values =
      evaluate(
        ~S"""
        new brick_class_methods #{target => Target} Brick.
        get_slots Brick #{filters => Filters, sources => Sources}.
        get Filters contents Active.
        member Active Instance, get Instance side "instance".
        get Sources contents Before.
        get Instance input Choice.
        set_slot Choice value 1.
        get Sources contents After.
        method Target own OwnMethod.
        method class_view_example_parent inherited InheritedMethod.
        """,
        %{"Target" => target()}
      )

    [own, class_side] = values["$Before"]
    [^own, inherited, ^class_side] = values["$After"]
    assert class_side.owner == :class_view_example_meta
    assert own.target == values["$OwnMethod"]
    assert inherited.target == values["$InheritedMethod"]
    assert length(inherited.clauses) == 2
    assert Enum.all?(inherited.clauses, &(&1.provenance == :retained))
    assert inherited.text =~ "first"
    assert inherited.text =~ "second"

    updated =
      evaluate(
        ~S"""
        class_view_example_child >> own
        | _Self updated |.
        refresh Brick.
        get Sources contents Current.
        """,
        %{"Brick" => values["$Brick"], "Sources" => values["$Sources"]}
      )["$Current"]

    [changed, ^inherited, ^class_side] = updated
    assert changed.target == own.target
    assert changed.text =~ "updated"
    refute changed.text == own.text
    %{before: values["$Before"], after: values["$After"], current: updated}
  end

  example filter_snapshot() do
    values =
      evaluate(
        ~S"""
        new class_up_to_filter #{target => Target, side => "instance", title => "Instance"} Filter.
        get Filter input Choice.
        get Choice choices Classes.
        length Classes Count.
        = Last (- Count 1).
        @class_view_example_child #{super => object, metaclass => class_view_example_meta}.
        set_slot Choice value Last.
        findall Class Included {
          member Classes Class,
          accepts Filter #{side => "instance", owner => Class}
        }.
        get Choice choices After.
        new class_up_to_filter #{target => Target, side => "instance", title => "Instance"} Current.
        get Current input CurrentChoice.
        get CurrentChoice choices CurrentClasses.
        """,
        %{"Target" => target()}
      )

    assert values["$Classes"] == values["$After"]
    assert values["$Included"] == values["$Classes"]
    refute :class_view_example_parent in values["$CurrentClasses"]
    %{shown: values["$Classes"], current: values["$CurrentClasses"]}
  end

  def render_timings(target \\ :object) do
    {construct, objects} =
      timed(~S(new brick_class_methods #{target => Target} Brick.), %{"Target" => target})

    bindings = %{"Brick" => objects["$Brick"]}

    {sources, rows} =
      timed(
        ~S"""
        get_slots Brick #{target => Target, filters => FilterModels}.
        get FilterModels contents Filters.
        method_sources Target Filters Sources.
        length Sources Count.
        """,
        bindings
      )

    {serialize, rendered} = timed("to_xaml Brick Xaml.", bindings)

    %{
      construct_ms: construct,
      sources_ms: sources,
      serialize_ms: serialize,
      rows: rows["$Count"],
      bytes: byte_size(rendered["$Xaml"])
    }
  end

  example source_editing() do
    values =
      evaluate(
        ~S"""
        method Target own Method.
        method_source Target Method Source.
        new source_edit #{source_record => Source} Edit.
        set_slot Edit text "local draft".
        class_view_example_child >> own
        | _Self external |.
        method_source Target Method Updated.
        refresh Edit Updated.
        get Edit text Draft.
        get Edit revert_action Revert.
        run Revert [].
        get Edit text Reverted.
        """,
        %{"Target" => target()}
      )

    assert values["$Draft"] == "local draft"
    assert values["$Reverted"] == values["$Updated"].text
    assert values["$Source"].target == values["$Updated"].target
    %{draft: values["$Draft"], reverted: values["$Reverted"]}
  end

  example delete_method() do
    values =
      evaluate(
        ~S"""
        new brick_class_methods #{target => Target} View.
        get_slots View #{filters => Filters, rows => Rows}.
        get Filters contents Active.
        member Active Instance, get Instance side "instance".
        get Instance input Choice.
        set_slot Choice value 1.
        get Rows contents [OwnRow, InheritedRow, ClassRow].
        get OwnRow edit Edit.
        get InheritedRow edit InheritedEdit.
        set_slot InheritedEdit text "keep this draft".
        get Edit source_record Source.
        get_slots Source #{target => Method, owner => Owner, selector => Selector}.
        get_slots Edit #{
          delete_action => Delete,
          confirm_delete_action => Confirm,
          cancel_delete_action => Cancel
        }.
        not (confirm_delete Edit).
        run Delete [].
        method Owner Selector Method.
        get Edit delete_pending true.
        run Cancel [].
        get Edit delete_pending false.
        not (confirm_delete Edit).
        method Owner Selector Method.
        run Delete [].
        run Confirm [].
        not (method Owner Selector Method).
        not (clause Method _Head _Body).
        get Rows contents Remaining.
        get InheritedEdit text Draft.
        """,
        %{"Target" => target()}
      )

    assert values["$Remaining"] == [values["$InheritedRow"], values["$ClassRow"]]
    assert values["$Draft"] == "keep this draft"
    %{remaining: values["$Remaining"], draft: values["$Draft"]}
  end

  example delete_shared_method() do
    values =
      evaluate(
        ~S"""
        method Target own Method.
        @class_view_example_alias #{super => object}.
        copy_methods class_view_example_alias [[alias, Method]].
        method_source Target Method Source.
        delete Source.
        not (method Target own Method).
        method class_view_example_alias alias Method.
        findall [Head, Body] Remaining (clause Method Head Body).
        method_source class_view_example_alias Method Alias.
        delete Alias.
        not (clause Method _Head _Body).
        """,
        %{"Target" => target()}
      )

    assert length(values["$Remaining"]) == 1
    values["$Method"]
  end

  example save_method() do
    values = method_edit()
    text = "class_view_example_child >> own\n| _Self saved |."

    evaluate("set_slot Edit text Text. get Edit save_action Save. run Save [].", %{
      "Edit" => values["$Edit"],
      "Text" => text
    })

    result =
      evaluate(
        ~S"""
        method class_view_example_child own Method.
        run Method [ignored, Result].
        vm_method_source Method _Sequence Retained Provenance.
        get_slots Edit #{text => Text, original_text => Original, error => Error, can_save => Ready}.
        """,
        %{"Edit" => values["$Edit"]}
      )

    assert result["$Method"] == values["$Method"]
    assert result["$Result"] == :saved
    assert result["$Retained"] == text
    assert result["$Provenance"] == :retained
    assert result["$Text"] == result["$Original"]
    assert result["$Ready"] && result["$Error"] == ""
    %{method: result["$Method"], source: result["$Retained"], value: result["$Result"]}
  end

  example save_rejects_invalid_or_changed_source() do
    for text <- [
          "not valid source",
          "class_view_example_child >> different\n| _Self wrong |.",
          "other_owner >> own\n| _Self wrong |."
        ] do
      values = method_edit()

      evaluate("set_slot Edit text Text. save Edit.", %{"Edit" => values["$Edit"], "Text" => text})

      result =
        evaluate(
          ~S"""
          get_slots Edit #{text => Text, error => Error, can_save => Ready}.
          method class_view_example_child own Method.
          run Method [ignored, Result].
          """,
          %{"Edit" => values["$Edit"]}
        )

      assert result["$Text"] == text
      assert result["$Error"] != ""
      assert result["$Ready"]
      assert result["$Method"] == values["$Method"]
      assert result["$Result"] == :original
    end

    values = method_edit()

    evaluate(
      ~S"""
      set_slot Edit text "class_view_example_child >> own\n| _Self local |.".
      class_view_example_child >> own
      | _Self external |.
      save Edit.
      """,
      %{"Edit" => values["$Edit"]}
    )

    result =
      evaluate(
        ~S"""
        get_slots Edit #{text => Text, error => Error, can_save => Ready}.
        method class_view_example_child own Method.
        run Method [ignored, Result].
        """,
        %{"Edit" => values["$Edit"]}
      )

    assert result["$Text"] =~ "local"
    assert result["$Error"] != ""
    assert result["$Ready"]
    assert result["$Result"] == :external
    %{draft: result["$Text"], current: result["$Result"]}
  end

  example save_class_sources() do
    values =
      evaluate(
        ~S"""
        definition_source Target Definition.
        new source_edit #{source_record => Definition} Edit.
        set_slot Edit text SourceText.
        save Edit.
        """,
        %{
          "Target" => target(),
          "SourceText" =>
            ~S"@class_view_example_child #{super => class_view_example_parent, metaclass => class_view_example_meta, ivars => [#{name => count, default => 0}]}."
        }
      )

    result =
      evaluate(
        ~S"""
        get class_view_example_child ivars Ivars.
        get_slots Edit #{text => Text, original_text => Text, error => "", can_save => true}.
        method class_view_example_child own Method.
        run Method [ignored, original].
        comment_source class_view_example_child Comment.
        new source_edit #{source_record => Comment} CommentEdit.
        set_slot CommentEdit text "Saved comment".
        save CommentEdit.
        get class_view_example_child comment CommentText.
        get CommentEdit original_text CommentText.
        """,
        %{"Edit" => values["$Edit"]}
      )

    assert result["$Ivars"] == [%{name: :count, default: 0}]
    assert result["$CommentText"] == "Saved comment"
    %{ivars: result["$Ivars"], comment: result["$CommentText"]}
  end

  example accepted_save_preserves_later_typing() do
    values = method_edit()

    result =
      evaluate(
        ~S"""
        get Edit source_record Source.
        class_view_example_child >> own
        | _Self saved |.
        set_slot Edit text "newer draft".
        saved Edit Source "class_view_example_child >> own\n| _Self saved |.".
        get_slots Edit #{text => Text, original_text => Original}.
        """,
        %{"Edit" => values["$Edit"]}
      )

    assert result["$Text"] == "newer draft"
    assert result["$Original"] =~ "saved"
    %{draft: result["$Text"], baseline: result["$Original"]}
  end

  defp method_edit() do
    evaluate(
      ~S"""
      method Target own Method.
      method_source Target Method Source.
      new source_edit #{source_record => Source} Edit.
      """,
      %{"Target" => target()}
    )
  end

  defp timed(source, bindings) do
    {time, result} = :timer.tc(fn -> evaluate(source, bindings) end)
    {time / 1000, result}
  end

  defp evaluate(source, bindings \\ %{}) do
    %AL{result: {:atomic, {values, _, _}}} =
      AL.run(source, branch: Examples.Support.branch(), bindings: bindings)

    values
  end
end
