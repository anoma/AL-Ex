defmodule AL.Edge do
  @moduledoc "I dispatch committed effects to statically installed host providers."

  alias AL.Goal

  @type effect_id() :: {atom(), non_neg_integer()}
  @type reply() ::
          :none
          | {term(), atom(), list()}
          | {:workflow, term(), atom(), non_neg_integer()}
  @type outcome() :: {:ok, term()} | {:error, term()}
  @type provider_result() :: outcome() | :pending

  @callback execute(atom(), list(), map()) :: provider_result()

  defmacro __using__(options) do
    provider = Keyword.fetch!(options, :provider)

    unless is_atom(provider) do
      raise ArgumentError, "edge provider must be an atom"
    end

    quote do
      @behaviour AL.Edge

      @doc false
      def __edge_provider__, do: unquote(provider)
    end
  end

  @spec register(module()) :: :ok
  def register(module) when is_atom(module) do
    Code.ensure_loaded!(module)

    unless function_exported?(module, :__edge_provider__, 0) do
      raise ArgumentError, "#{inspect(module)} must use AL.Edge with a provider"
    end

    unless function_exported?(module, :execute, 3) do
      raise ArgumentError, "#{inspect(module)} must export execute/3"
    end

    AL.Edge.Registry.put(module.__edge_provider__(), module)
  end

  @spec unregister(atom()) :: :ok
  def unregister(provider), do: AL.Edge.Registry.delete(provider)

  @spec register_all([module()]) :: :ok
  def register_all(entries) do
    Enum.each(entries, &register/1)
    :ok
  end

  @spec emit(non_neg_integer(), atom(), atom(), list(), reply(), AL.Branch.t()) :: effect_id()
  def emit(tx_id, provider, operation, arguments, reply, branch) do
    validate_request!(provider, operation, arguments, reply)
    time = AL.Command.effect(tx_id, provider, operation, arguments, reply, branch)
    {branch.id, time}
  end

  @spec dispatch(effect_id(), atom(), atom(), list(), reply(), AL.Branch.t()) ::
          :ok | :pending | {:error, term()}
  def dispatch(effect_id, provider, operation, arguments, reply, branch) do
    ensure_outside_transaction!(:dispatch)
    context = %{effect_id: effect_id, branch: branch, reply: reply}

    case invoke(provider, operation, arguments, context) do
      :pending -> :pending
      outcome -> complete(context, outcome)
    end
  end

  @spec complete(map(), outcome()) :: :ok | {:error, term()}
  def complete(
        %{effect_id: effect_id, branch: branch, reply: reply},
        {status, _value} = outcome
      )
      when status in [:ok, :error] do
    ensure_outside_transaction!(:complete)

    with :ok <- validate_outcome(outcome) do
      deliver(reply, effect_id, outcome, branch)
    end
  end

  def complete(_context, outcome), do: {:error, {:invalid_effect_outcome, outcome}}

  defp invoke(provider, operation, arguments, context) do
    case AL.Edge.Registry.lookup(provider) do
      nil ->
        {:error, {:effect_provider_missing, provider}}

      module ->
        try do
          module.execute(operation, arguments, context)
          |> normalize_result()
        rescue
          exception -> {:error, {:effect_exception, Exception.message(exception)}}
        catch
          kind, reason -> {:error, {:effect_throw, kind, inspect(reason)}}
        end
    end
  end

  defp normalize_result(:pending), do: :pending

  defp normalize_result({status, _value} = outcome) when status in [:ok, :error] do
    case validate_outcome(outcome) do
      :ok -> outcome
      {:error, _reason} -> {:error, {:invalid_effect_result, inspect(outcome)}}
    end
  end

  defp normalize_result(other), do: {:error, {:invalid_effect_result, inspect(other)}}

  defp deliver(:none, _effect_id, _outcome, _branch), do: :ok

  defp deliver({:workflow, workflow, selector, step}, effect_id, outcome, branch) do
    AL.Workflow.resume(workflow, selector, step, effect_id, outcome, branch)
  end

  defp deliver({receiver, selector, prefix_arguments}, effect_id, outcome, branch) do
    goal = %Goal.Send{
      object: receiver,
      method: selector,
      args: prefix_arguments ++ [effect_id, outcome]
    }

    case AL.eval([goal], nil, branch) do
      {:atomic, _result} -> :ok
      {:aborted, reason} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_request!(provider, operation, arguments, reply) do
    unless is_atom(provider), do: raise(ArgumentError, "effect provider must be an atom")
    unless is_atom(operation), do: raise(ArgumentError, "effect operation must be an atom")
    unless is_list(arguments), do: raise(ArgumentError, "effect arguments must be a list")

    unless reply == :none or valid_reply?(reply) do
      raise ArgumentError,
            "effect reply must be :none, {receiver, selector, prefix_arguments}, or a workflow reply"
    end

    request = {provider, operation, arguments, reply}

    unless MapSet.size(AL.Var.find_vars(request)) == 0 do
      raise ArgumentError, "effect request must be ground"
    end

    AL.Goal.validate_storable!(request)

    unless durable?(request) do
      raise ArgumentError, "effect request contains a live host value"
    end

    :ok
  end

  defp validate_outcome(outcome) do
    cond do
      MapSet.size(AL.Var.find_vars(outcome)) != 0 ->
        {:error, {:effect_outcome_not_ground, outcome}}

      not durable?(outcome) ->
        {:error, {:effect_outcome_contains_live_value, outcome}}

      true ->
        case AL.Goal.validate_storable(outcome) do
          :ok -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp valid_reply?({_receiver, selector, prefix_arguments}) do
    is_atom(selector) and is_list(prefix_arguments)
  end

  defp valid_reply?({:workflow, _workflow, selector, step}) do
    is_atom(selector) and is_integer(step) and step >= 0
  end

  defp valid_reply?(_reply), do: false

  defp durable?(term)
       when is_pid(term) or is_port(term) or is_reference(term) or is_function(term),
       do: false

  defp durable?([]), do: true
  defp durable?([head | tail]), do: durable?(head) and durable?(tail)

  defp durable?(term) when is_map(term) do
    Enum.all?(term, fn {key, value} -> durable?(key) and durable?(value) end)
  end

  defp durable?(term) when is_tuple(term) do
    term |> Tuple.to_list() |> Enum.all?(&durable?/1)
  end

  defp durable?(_term), do: true

  defp ensure_outside_transaction!(operation) do
    if :mnesia.is_transaction() do
      raise ArgumentError, "AL.Edge.#{operation} must run outside an AL/Mnesia transaction"
    end
  end
end
