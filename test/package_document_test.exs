defmodule ALPackageDocumentTest do
  use ExUnit.Case, async: true

  alias AL.Package.Document

  defp document(overrides \\ []) do
    struct!(Document, Keyword.merge([name: :interval, version: 1, deps: []], overrides))
  end

  test "a package manifest round trips" do
    document = document(deps: [:mapset, :values])
    text = Document.render(document)

    assert text == "defpackage interval \#{deps => [mapset, values], version => 1}.\n"
    assert {:ok, ^document} = Document.parse(text)
  end

  test "manifest metadata is data, not code" do
    text = String.replace(Document.render(document()), "version => 1", "version => (halt)")
    assert {:error, {:invalid_package_document, _reason}} = Document.parse(text)

    text = String.replace(Document.render(document()), "version => 1", "version => V")
    assert {:error, {:invalid_package_document, _reason}} = Document.parse(text)
  end

  test "dependency requirements are written as name and requirement pairs" do
    document = document(deps: [{:values, %{version: %{at_least: [0, 1]}}}])
    text = Document.render(document)

    assert text =~ "deps => [[values, \#{version => \#{at_least => [0, 1]}}]]"
    assert {:ok, ^document} = Document.parse(text)
  end

  test "the manifest has no other fields or forms" do
    text =
      String.replace(Document.render(document()), "deps => []", "deps => [], transactions => []")

    assert {:error, {:invalid_package_document, _reason}} = Document.parse(text)

    text = Document.render(document()) <> "vm_set_class x object.\n"
    assert {:error, {:invalid_package_document, _reason}} = Document.parse(text)
  end
end
