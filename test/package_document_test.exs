defmodule ALPackageDocumentTest do
  use ExUnit.Case, async: true

  alias AL.Package.Document

  defp document(overrides \\ []) do
    struct!(Document, Keyword.merge([name: :interval, version: 1, deps: []], overrides))
  end

  test "a package manifest round trips" do
    document = document()
    assert {:ok, ^document} = document |> Document.render() |> Document.parse()
  end

  test "manifest metadata cannot execute Elixir code" do
    text = Document.render(document())
    malicious = String.replace(text, "#version : 1", "#version : System.halt()")

    assert {:error, {:invalid_package_document, _reason}} = Document.parse(malicious)
  end

  test "dependency requirements remain literal data" do
    document = document(deps: [{:values, "> 0.1"}])
    assert {:ok, ^document} = document |> Document.render() |> Document.parse()

    invalid = document(deps: [{:values, System}]) |> Document.render()
    assert {:error, {:invalid_package_document, _reason}} = Document.parse(invalid)
  end

  test "the manifest has no transaction or member fields" do
    text =
      Document.render(document())
      |> String.replace("#deps : []", "#deps : [],\n  #transactions : []")

    assert {:error, {:invalid_package_document, _reason}} = Document.parse(text)
  end
end
