defmodule Examples.ALViewsWindowManager do
  use ExExample
  import ExUnit.Assertions

  def rerun?(_), do: true

  example point(x \\ 3, y \\ 4) do
    values =
      evaluate(~S(new point #{x => X, y => Y} Point, x Point ActualX, y Point ActualY.), %{
        "X" => x,
        "Y" => y
      })

    assert values["$ActualX"] == x
    assert values["$ActualY"] == y
    values["$Point"]
  end

  example empty_window_manager() do
    evaluate(
      ~S"""
      new point #{} Total.
      new single_layout #{windows => []} Layout.
      new wm #{layout => Layout, visible_extent => Visible, total_extent => Total} Wm.
      """,
      %{"Visible" => point(800, 600)}
    )["$Wm"]
  end

  example resized_window_manager() do
    wm = empty_window_manager()

    values =
      evaluate("viewport_changed Wm Updated Changed Removed.", %{
        "Wm" => wm,
        "Updated" => point(1200, 900)
      })

    assert values["$Changed"] == []
    assert values["$Removed"] == []
    wm
  end

  example builder() do
    evaluate(~S(new phlow_builder #{} Builder.))["$Builder"]
  end

  example text_view(fields \\ %{title: "Sample", text: "Hello", grammar: "al"}) do
    evaluate("text Builder Class, new Class Fields View.", %{
      "Builder" => builder(),
      "Fields" => fields
    })["$View"]
  end

  example text_description() do
    view = text_view()

    values =
      evaluate(
        ~S"""
        to_map View Fields.
        get View brick Brick.
        get_slots Brick #{text => Text, grammar => Grammar}.
        to_map View Again.
        """,
        %{"View" => view}
      )

    fields = values["$Fields"]
    assert Map.drop(fields, [:content]) == %{priority: 100, title: "Sample", view: "xaml"}
    assert fields == values["$Again"]
    refute Map.has_key?(view, :text)
    refute Map.has_key?(view, :grammar)
    assert values["$Text"] == "Hello"
    assert values["$Grammar"] == "al"
    assert fields.content =~ "<ae:TextEditor>"
    assert fields.content =~ "<editor:Code.Text><al:BindExtension Path=\"text\""
    assert fields.content =~ "<editor:Code.Grammar>al</editor:Code.Grammar>"
    assert fields.content =~ "<ae:TextEditor.IsReadOnly>true</ae:TextEditor.IsReadOnly>"
    assert fields.content =~ "<ae:TextEditor.Options><ae:TextEditorOptions>"

    assert fields.content =~
             "<ae:TextEditorOptions.AllowScrollBelowDocument>false</ae:TextEditorOptions.AllowScrollBelowDocument>"

    fields
  end

  example views_without_window_manager() do
    branch = Examples.Support.isolated_branch()

    try do
      %AL{result: {:atomic, {values, _, _}}} =
        AL.run(
          ~S"""
          deactivate window_manager.
          new phlow_text #{title => "Plain", text => "<&"} View.
          to_map View Fields.
          get View brick Brick.
          get_slots Brick #{text => Text, grammar => Grammar}.
          new brick_textbox #{text => "hello", placeholder_text => "<&"} Box.
          to_xaml Box Xaml.
          """,
          branch
        )

      assert values["$Text"] == "<&"
      assert values["$Grammar"] == ""
      assert values["$Fields"].content =~ "<editor:Code.Grammar></editor:Code.Grammar>"
      assert values["$Xaml"] =~ "<TextBox.Text><al:BindExtension"
      assert values["$Xaml"] =~ "<TextBox.PlaceholderText>&lt;&amp;</TextBox.PlaceholderText>"
      %{text: values["$Fields"], textbox: values["$Xaml"]}
    after
      AL.Branch.discard(branch)
    end
  end

  example table_view(fields \\ %{title: "Methods", items: [], columns: [], row_spacing: 8}) do
    evaluate("list Builder Class, new Class Fields View.", %{
      "Builder" => builder(),
      "Fields" => fields
    })["$View"]
  end

  example table_description() do
    fields = describe(table_view())

    assert Map.drop(fields, [:content]) == %{
             priority: 100,
             title: "Methods",
             view: "xaml",
             data: []
           }

    assert fields.content =~ "<TableView "
    assert fields.content =~ "Value=\"0,0,0,8\""
    fields
  end

  example object_views(target \\ :object) do
    views =
      evaluate("findall Map Views {view Target Builder View, to_map View Map}.", %{
        "Builder" => builder(),
        "Target" => target
      })["$Views"]

    assert Enum.find(views, &(&1[:title] == "meta"))[:content] =~ "Value=\"0,0,0,8\""
    views
  end

  example xaml_names() do
    names = %{
      "" => "",
      "_" => "",
      "__text__value_" => "TextValue",
      "text" => "Text",
      "is_read_only" => "IsReadOnly",
      "allow_scroll_below_document" => "AllowScrollBelowDocument",
      "XML_name" => "XMLName",
      "é_世界" => "é世界"
    }

    for {raw, expected} <- names, into: %{} do
      name =
        evaluate("pascal_case Slot Raw Name.", %{"Slot" => %{class: :xaml_slot}, "Raw" => raw})[
          "$Name"
        ]

      assert name == expected
      {raw, name}
    end
  end

  example xaml_escaping() do
    strings = %{
      "" => "",
      "plain é 世界" => "plain é 世界",
      "<&>\"\t\n\r" => "&lt;&amp;&gt;&quot;&#9;&#10;&#13;",
      "&amp;" => "&amp;amp;",
      "a<&b" => "a&lt;&amp;b"
    }

    for {raw, expected} <- strings, into: %{} do
      text =
        evaluate("xml_escape Slot Raw Text.", %{"Slot" => %{class: :xaml_slot}, "Raw" => raw})[
          "$Text"
        ]

      assert text == expected
      {raw, text}
    end
  end

  example inherited_xaml_properties() do
    values =
      evaluate(~S"""
      @xaml_example_base
      #{super => [value, brick_text_block], ivars => [#{name => font_size, default => 11, xaml => xaml_literal_property}]}.
      @xaml_example_child
      #{super => xaml_example_base, ivars => [#{name => font_size, default => 16, xaml => xaml_literal_property}]}.
      new xaml_example_child #{width => 0, text => "<&"} Brick.
      to_xaml Brick Xaml.
      """)

    xaml = values["$Xaml"]
    assert xaml =~ "<TextBlock.FontSize>16</TextBlock.FontSize>"
    assert xaml =~ "<TextBlock.Width>0</TextBlock.Width>"
    assert xaml =~ "<TextBlock.Text>&lt;&amp;</TextBlock.Text>"
    refute xaml =~ "TextBlock.Margin"
    xaml
  end

  example raw_view() do
    evaluate(~S(new phlow_raw #{title => "Raw", target => #{value => Open}} View.))["$View"]
  end

  example raw_description() do
    fields = describe(raw_view())
    assert fields.view == "xaml"
    assert fields.data == fields.target
    assert fields.content =~ "<Binding Path=\".\" Mode=\"OneWay\"/>"
    refute fields.content =~ "al:BindExtension"
    fields
  end

  example editor_columns() do
    [
      %{header: "<&", cell: :brick_editor_cell, grammar: "al"},
      %{header: "Text", cell: :brick_text, text: "name"}
    ]
  end

  example editor_table() do
    table_view(%{title: "Cells", items: [], columns: editor_columns()})
  end

  example editor_table_description() do
    fields = describe(editor_table())
    assert fields.view == "xaml"
    assert fields.data == []
    assert fields.content =~ "<TableViewColumn.Header>&lt;&amp;</TableViewColumn.Header>"
    assert fields.content =~ "<DataTemplate><ae:TextEditor>"
    assert fields.content =~ "<DataTemplate><TextBlock>"
    assert fields.content =~ "ConverterParameter=\"name\""
    assert fields.content =~ "<editor:Code.Grammar>al</editor:Code.Grammar>"
    assert fields.content =~ "<editor:Code.FollowCaret>true</editor:Code.FollowCaret>"

    assert fields.content =~
             "<ae:TextEditor.VerticalScrollBarVisibility>Disabled</ae:TextEditor.VerticalScrollBarVisibility>"

    fields
  end

  def describe(view), do: evaluate("to_map View Fields.", %{"View" => view})["$Fields"]

  defp evaluate(source, bindings \\ %{}) do
    %AL{result: {:atomic, {values, _, _}}} =
      AL.run(source, branch: Examples.Support.branch(), bindings: bindings)

    values
  end
end
