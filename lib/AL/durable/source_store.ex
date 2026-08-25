defmodule AL.SourceStore do
  @moduledoc """
  Stores exact source inputs and definition spans for each branch.

  Source rows are an append-only presentation archive. `AL.Command` remains
  authoritative for executable state.
  """

  @relations %{
    source_text: [:tx_id, :text, :origin],
    source_span: [:command_t, :tx_id, :kind, :range, :context]
  }

  @type origin() :: %{optional(atom()) => term(), kind: atom()}
  @type source_range() :: AL.Source.Parser.Capture.source_range()
  @type source_text_record() :: {:source_text, non_neg_integer(), String.t(), origin()}
  @type source_span_record() ::
          {:source_span, non_neg_integer(), non_neg_integer(), :defmethod | :defclass,
           source_range(), map()}

  @spec table(atom(), AL.Branch.t()) :: atom()
  def table(relation, branch \\ AL.Branch.head()), do: AL.Command.table(relation, branch)

  @doc "Create both source tables for a branch. This function is idempotent."
  @spec create_tables(AL.Branch.t()) :: :ok
  def create_tables(branch) do
    for {relation, attributes} <- @relations do
      reference = table(relation, branch)

      case :mnesia.create_table(reference,
             attributes: attributes,
             type: :set,
             disc_copies: [AL.Command.owner_node()],
             record_name: relation
           ) do
        {:atomic, :ok} -> :ok
        {:aborted, {:already_exists, _}} -> :ok
      end

      AL.Command.ensure_local_copy(reference)
    end

    :mnesia.wait_for_tables(Enum.map(Map.keys(@relations), &table(&1, branch)), 5_000)
    :ok
  end

  @doc "Delete both source tables for a branch."
  @spec drop_tables(AL.Branch.t()) :: :ok
  def drop_tables(branch) do
    for relation <- Map.keys(@relations), do: :mnesia.delete_table(table(relation, branch))
    :ok
  end

  @doc "Copy source rows whose command anchors are in a copied command prefix."
  @spec copy_prefix(AL.Branch.t(), AL.Branch.t(), integer()) ::
          {:atomic, :ok} | {:aborted, term()}
  def copy_prefix(source, destination, command_cutoff) do
    :mnesia.transaction(fn ->
      spans =
        :mnesia.select(table(:source_span, source), [
          {{:source_span, :"$1", :"$2", :"$3", :"$4", :"$5"}, [{:"=<", :"$1", command_cutoff}],
           [:"$_"]}
        ])

      for span <- spans, do: :mnesia.write(table(:source_span, destination), span, :write)

      spans
      |> Enum.map(fn {:source_span, _command_t, tx_id, _kind, _range, _context} -> tx_id end)
      |> Enum.uniq()
      |> Enum.each(fn tx_id ->
        case :mnesia.read(table(:source_text, source), tx_id) do
          [text] -> :mnesia.write(table(:source_text, destination), text, :write)
          [] -> :ok
        end
      end)

      :ok
    end)
  end

  @spec put_text(non_neg_integer(), String.t(), origin(), AL.Branch.t()) :: :ok
  def put_text(tx_id, text, origin, branch \\ AL.Branch.head()) do
    :mnesia.write(table(:source_text, branch), {:source_text, tx_id, text, origin}, :write)
    :ok
  end

  @spec put_span(
          non_neg_integer(),
          non_neg_integer(),
          :defmethod | :defclass,
          source_range(),
          map(),
          AL.Branch.t()
        ) :: :ok
  def put_span(command_t, tx_id, kind, range, context, branch \\ AL.Branch.head()) do
    row = {:source_span, command_t, tx_id, kind, range, context}
    :mnesia.write(table(:source_span, branch), row, :write)
    :ok
  end

  @spec text(non_neg_integer(), AL.Branch.t()) :: source_text_record() | :absent
  def text(tx_id, branch \\ AL.Branch.head()) do
    case :mnesia.read(table(:source_text, branch), tx_id) do
      [row] -> row
      [] -> :absent
    end
  end

  @spec span(non_neg_integer(), AL.Branch.t()) :: source_span_record() | :absent
  def span(command_t, branch \\ AL.Branch.head()) do
    case :mnesia.read(table(:source_span, branch), command_t) do
      [row] -> row
      [] -> :absent
    end
  end

  @spec texts(AL.Branch.t()) :: [source_text_record()]
  def texts(branch \\ AL.Branch.head()) do
    :mnesia.select(table(:source_text, branch), [{{:source_text, :_, :_, :_}, [], [:"$_"]}])
    |> Enum.sort_by(fn {:source_text, tx_id, _text, _origin} -> tx_id end)
  end

  @spec spans(AL.Branch.t()) :: [source_span_record()]
  def spans(branch \\ AL.Branch.head()) do
    :mnesia.select(table(:source_span, branch), [
      {{:source_span, :_, :_, :_, :_, :_}, [], [:"$_"]}
    ])
    |> Enum.sort_by(fn {:source_span, command_t, _tx_id, _kind, _range, _context} ->
      command_t
    end)
  end
end
