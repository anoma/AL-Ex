Class {
  #name : :peer_connection,
  #superclass : [:object],
  #metaclass : :class,
  #ivars : [
    :socket,
    %{name: :state, default: :connecting}
  ]
}
