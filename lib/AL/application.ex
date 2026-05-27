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
      
      {:set_method, :class, :meta, :metaclass},
      {:set_method, :class, :new, :new_object},
      
      {:set_method, :object, :lookup, :lookup},
      {:set_method, :object, :send, :send},
      {:set_method, :object, :init, :initialise_object},

      {:set_class, :get_name, :behaviour},
      {:set_oapply, :get_name,
       [%{name: :"$name"}, :"$name"],
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
       [
         {:or,
         [{:get_method, :"$self", :"$name", :"$method_id"}],
         [{:get_super, :"$self", :"$super"},
          {:exec, :lookup, [:"$super", :"$name", :"$method_id"]}]
        }
       ]
      },

      {:set_class, :new_object, :behaviour},
      {:set_oapply, :new_object,
       [:"$self", :"$args", :"$new"],
       [
         {:sendb, :"$self", :allocate, :"$args"},
         {:exec, :get_name, [:"$args", :"$alloc"]},
         {:sendb, :"$alloc", :init, :"$args"}
       ]
      },

      {:set_class, :send, :behaviour},
      {:set_oapply, :send,
       [:"$self", :"$method_name", :"$args"],
       [
         {:get_class, :"$self", :"$class"},
         {:implies,
          [{:exec, :lookup, [:"$class", :"$method_name", :"$method_id"]}],
          [
            {:print, ["calling", :"$method_id",
                      "from", :"$class",
                      "with args", [:"$self" | :"$args"]]},
            {:exec, :"$method_id", [:"$self" | :"$args"]}],
          [:fail]
         }
       ]
      },

      {:set_class, :initialise_object, :behaviour},
      {:set_oapply, :initialise_object,
       [:"$self", :"$_", :"$state"],
       [{:print, :"$self"}]}
    ])
  end
end
