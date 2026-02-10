defmodule AL.Application do
  @moduledoc """
  I am the top level OTP application callback module for AL.
  I manage both the event server and object server.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      AL.Events,
      AL.Objects
      # {DynamicSupervisor, name: QueryEngineSupervisor}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Al.Supervisor]
    Supervisor.start_link(children, opts)
  end

  def bootstrap() do
    AL.eval([
      {:set_class, :class, :class},
      {:set_class, :behaviour, :class},
      {:set_super, :class, :object},
      {:set_method, :class, :init, :initialise_class},
      {:set_method, :class, :meta, :metaclass},
      {:set_class, :initialise_class, :behaviour},
      {:set_oapply, :initialise_class,
       [:"$self", %{name: :"$name"}, :"$_"],
       [
         {:set_class, :"$name", :"$self"}
       ]
      },
      {:set_class, :metaclass, :behaviour},
      {:set_oapply, :metaclass,
       [:"$self", :"$class", :"$meta"],
       [
         {:get_class, :"$self", :"$class"},
         {:get_class, :"$class", :"$meta"}
       ]
      }
    ])
  end
end
