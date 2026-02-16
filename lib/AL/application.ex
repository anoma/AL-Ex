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
      {:set_method, :class, :allocate, :allocate_class},
      {:set_method, :class, :meta, :metaclass},
      {:set_method, :object, :lookup, :lookup},
      
      {:set_class, :initialise_class, :behaviour},
      {:set_oapply, :initialise_class,
       [:"$self", %{name: :"$name", super: :"$super", slots: :"$slots"}, :"$_"],
       [
         {:get_class, :"$self", :"$meta"},
         {:set_class, :"$name", :"$meta"},
         {:set_super, :"$name", :"$super"},
         {:set_slots, :"$name", :"$slots"}
       ]
      },

      {:set_class, :allocate_class, :behaviour},
      {:set_oapply, :allocate_class,
       [:"$self", %{class: :"$self"}],
       []},
      
      {:set_class, :metaclass, :behaviour},
      {:set_oapply, :metaclass,
       [:"$self", :"$class", :"$meta"],
       [
         {:get_class, :"$self", :"$class"},
         {:get_class, :"$class", :"$meta"}
       ]
      },

      {:set_class, :lookup, :behaviour},
      {:set_oapply, :lookup,
       [:"$self", :"$name", :"$method_id"],
       [{:or,
         [{:get_method, :"$self", :"$name", :"$method_id"}],
         [{:get_super, :"$self", :"$super"},
          {:exec, :lookup, [:"$super", :"$name", :"$method_id"]}]
        }
       ]
      }
    ])
  end
end
