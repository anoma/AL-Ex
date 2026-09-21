defmodule AL.Edge do
  @moduledoc "I dispatch committed effects and admit host messages into AL."

  alias AL.Goal

  @type effect_id() :: term()
  @type outcome() :: {:ok, term()} | {:error, term()}
  @type notification() :: {term(), atom(), list()}
  @type provider_result() :: outcome() | {:notify, outcome(), [notification()]} | :pending

  @callback __edge_provider__() :: atom()
  @callback execute(atom(), list(), map()) :: provider_result()

  defmacro __using__(options) do
    provider = Keyword.fetch!(options, :provider)

    unless is_atom(provider) do
      raise ArgumentError, "edge provider must be an atom"
    end

    quote do
      @behaviour AL.Edge

      @impl AL.Edge
      def __edge_provider__, do: unquote(provider)
    end
  end

  @spec register(module()) :: :ok
  def register(module) when is_atom(module) do
    Code.ensure_loaded!(module)

    unless function_exported?(module, :__edge_provider__, 0) do
      raise ArgumentError, "#{inspect(module)} must export __edge_provider__/0"
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

  @spec request(non_neg_integer(), effect_id(), atom(), atom(), list(), AL.Branch.t()) ::
          non_neg_integer()
  def request(tx_id, effect, provider, operation, arguments, branch) do
    validate_object_request!(effect, provider, operation, arguments)
    AL.Command.effect_object(tx_id, effect, provider, operation, arguments, branch)
  end

  @spec receive(term(), term(), AL.Branch.t()) :: :ok | {:error, term()}
  def receive(receiver, value, branch) do
    notify(receiver, :receive, [value], branch)
  end

  @spec await(effect_id(), keyword()) :: outcome() | {:error, term()}
  def await(effect, options \\ []) when is_atom(effect) and is_list(options) do
    branch = options |> Keyword.get(:branch, AL.Branch.head()) |> branch!()
    timeout = Keyword.get(options, :timeout, 5_000)

    if is_integer(timeout) and timeout >= 0 do
      case AL.Events.await({:effect, branch.id, effect}, timeout, fn ->
             await_result(effect, branch)
           end) do
        {:ok, result} -> result
        :timeout -> {:error, {:effect_timeout, effect}}
      end
    else
      {:error, {:invalid_effect_timeout, timeout}}
    end
  end

  @spec call(term(), atom(), list(), AL.Branch.t()) :: {:ok, term()} | {:error, term()}
  def call(receiver, selector, arguments, branch) when is_atom(selector) and is_list(arguments) do
    ensure_outside_transaction!(:call)
    reply = AL.Var.var("edge_reply")
    goal = %Goal.Send{object: receiver, method: selector, args: arguments ++ [reply]}

    case AL.eval([goal], nil, branch) do
      {:atomic, {bindings, _constraints, _state}} ->
        call_reply(bindings, reply)

      {:aborted, reason} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec notify(term(), atom(), list(), AL.Branch.t()) :: :ok | {:error, term()}
  def notify(receiver, selector, arguments, branch) do
    ensure_outside_transaction!(:notify)

    goal = %Goal.Send{object: receiver, method: selector, args: arguments}

    case AL.eval([goal], nil, branch) do
      {:atomic, _result} ->
        :ok

      {:aborted, reason} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec dispatch(effect_id(), atom(), atom(), list(), AL.Branch.t()) ::
          :ok | :pending | {:error, term()}
  def dispatch(effect_id, provider, operation, arguments, branch) do
    ensure_outside_transaction!(:dispatch)
    context = %{effect_id: effect_id, branch: branch}

    case invoke(provider, operation, arguments, context) do
      :pending -> :pending
      {:complete, outcome, notifications} -> complete(context, outcome, notifications)
    end
  end

  @spec complete(map(), outcome()) :: :ok | {:error, term()}
  def complete(%{effect_id: effect_id, branch: branch}, {status, _value} = outcome)
      when status in [:ok, :error] do
    complete(%{effect_id: effect_id, branch: branch}, outcome, [])
  end

  def complete(_context, outcome), do: {:error, {:invalid_effect_outcome, outcome}}

  @spec complete(map(), outcome(), [notification()]) :: :ok | {:error, term()}
  def complete(
        %{effect_id: effect_id, branch: branch},
        {status, _value} = outcome,
        notifications
      )
      when status in [:ok, :error] and is_list(notifications) do
    ensure_outside_transaction!(:complete)

    with :ok <- validate_outcome(outcome),
         :ok <- validate_notifications(notifications) do
      goals =
        [%Goal.Send{object: effect_id, method: :complete, args: [al_outcome(outcome)]}] ++
          Enum.map(notifications, fn {receiver, selector, arguments} ->
            %Goal.Send{object: receiver, method: selector, args: arguments}
          end)

      case AL.eval(goals, nil, branch) do
        {:atomic, _result} ->
          AL.Events.publish({:effect, branch.id, effect_id})
          :ok

        {:aborted, reason} ->
          {:error, reason}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def complete(_context, outcome, notifications),
    do: {:error, {:invalid_effect_completion, outcome, notifications}}

  defp invoke(provider, operation, arguments, context) do
    case AL.Edge.Registry.lookup(provider) do
      nil ->
        {:complete, {:error, {:effect_provider_missing, provider}}, []}

      module ->
        try do
          module.execute(operation, arguments, context)
          |> normalize_result()
        rescue
          exception ->
            {:complete, {:error, {:effect_exception, Exception.message(exception)}}, []}
        catch
          kind, reason -> {:complete, {:error, {:effect_throw, kind, inspect(reason)}}, []}
        end
    end
  end

  defp await_result(effect, branch) do
    case :mnesia.transaction(fn -> AL.Object.read_slots(effect, branch) end) do
      {:atomic, [{:slots, ^effect, %{status: :completed, outcome: outcome}}]} ->
        {:ok, host_outcome(outcome)}

      {:atomic, [{:slots, ^effect, %{status: :pending}}]} ->
        :pending

      {:atomic, []} ->
        {:ok, {:error, {:effect_not_found, effect}}}

      {:atomic, rows} ->
        {:ok, {:error, {:invalid_effect_rows, effect, rows}}}

      {:aborted, reason} ->
        {:ok, {:error, {:effect_read_failed, effect, reason}}}
    end
  end

  defp branch!(%AL.Branch{} = branch), do: branch
  defp branch!(id) when is_atom(id), do: %AL.Branch{id: id}

  defp branch!(value) do
    raise ArgumentError, "effect branch must be an atom or AL.Branch, got: #{inspect(value)}"
  end

  defp al_outcome({:ok, value}), do: %{status: :ok, value: value}
  defp al_outcome({:error, reason}), do: %{status: :error, reason: reason}

  defp host_outcome(%{status: :ok, value: value}), do: {:ok, value}
  defp host_outcome(%{status: :error, reason: reason}), do: {:error, reason}
  defp host_outcome(outcome), do: {:error, {:invalid_effect_outcome, outcome}}

  defp normalize_result(:pending), do: :pending

  defp normalize_result({status, _value} = outcome) when status in [:ok, :error] do
    case validate_outcome(outcome) do
      :ok -> {:complete, outcome, []}
      {:error, _reason} -> {:complete, {:error, {:invalid_effect_result, inspect(outcome)}}, []}
    end
  end

  defp normalize_result({:notify, {status, _value} = outcome, notifications})
       when status in [:ok, :error] and is_list(notifications) do
    with :ok <- validate_outcome(outcome),
         :ok <- validate_notifications(notifications) do
      {:complete, outcome, notifications}
    else
      {:error, _reason} ->
        {:complete, {:error, {:invalid_effect_result, inspect({outcome, notifications})}}, []}
    end
  end

  defp normalize_result(other),
    do: {:complete, {:error, {:invalid_effect_result, inspect(other)}}, []}

  defp validate_request!(provider, operation, arguments) do
    unless is_atom(provider), do: raise(ArgumentError, "effect provider must be an atom")
    unless is_atom(operation), do: raise(ArgumentError, "effect operation must be an atom")
    unless is_list(arguments), do: raise(ArgumentError, "effect arguments must be a list")

    request = {provider, operation, arguments}

    unless MapSet.size(AL.Var.find_vars(request)) == 0 do
      raise ArgumentError, "effect request must be ground"
    end

    AL.Goal.validate_storable!(request)

    unless durable?(request) do
      raise ArgumentError, "effect request contains a live host value"
    end

    :ok
  end

  defp validate_object_request!(effect, provider, operation, arguments) do
    validate_request!(provider, operation, arguments)
    request = {effect, provider, operation, arguments}

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

  defp validate_notifications(notifications) do
    if Enum.all?(notifications, &valid_notification?/1) do
      :ok
    else
      {:error, {:invalid_effect_notifications, notifications}}
    end
  end

  defp valid_notification?({_receiver, selector, arguments} = notification)
       when is_atom(selector) and is_list(arguments) do
    MapSet.size(AL.Var.find_vars(notification)) == 0 and durable?(notification) and
      AL.Goal.validate_storable(notification) == :ok
  end

  defp valid_notification?(_notification), do: false

  defp call_reply(bindings, reply) do
    case Map.fetch(bindings, reply) do
      {:ok, value} ->
        with :ok <- validate_outcome({:ok, value}) do
          {:ok, value}
        end

      :error ->
        {:error, {:edge_call_reply_missing, reply}}
    end
  end

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
