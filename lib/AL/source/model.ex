defmodule AL.Source.Ref do
  @moduledoc "An ephemeral reference from one source capture to its defining command."

  @type capture_id() :: {reference(), non_neg_integer()}
  @type t() :: %__MODULE__{
          capture_id: capture_id(),
          tx_id: non_neg_integer() | nil,
          kind: :defmethod | :defclass,
          range: AL.Source.Parser.Capture.source_range(),
          authored_as: :standalone | :nested,
          context: map() | nil
        }

  @enforce_keys [:capture_id, :kind, :range, :authored_as]
  defstruct [:capture_id, :tx_id, :kind, :range, :authored_as, :context]
end

defmodule AL.Source.Evaluation do
  @moduledoc "A source-aware AL program prepared before its Mnesia transaction."

  @type t() :: %__MODULE__{
          text: String.t(),
          origin: AL.SourceStore.origin(),
          program: [AL.Goal.t()],
          refs: %{AL.Source.Ref.capture_id() => AL.Source.Ref.t()}
        }

  @enforce_keys [:text, :origin, :program, :refs]
  defstruct [:text, :origin, :program, :refs]
end

defmodule AL.Source.ProvenanceError do
  @moduledoc "A missing, duplicate, or mismatched source command anchor."

  defexception [:capture_id, :reason]

  @impl true
  def message(%__MODULE__{capture_id: capture_id, reason: reason}) do
    "invalid source provenance for #{inspect(capture_id)}: #{inspect(reason)}"
  end
end
