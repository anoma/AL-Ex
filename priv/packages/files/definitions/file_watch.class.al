@file_watch
#{
  super: object,
  ivars: [
    #{name: path},
    #{default: idle, name: status},
    #{default: none, name: contents}
  ]
}.

file_watch >> init
| Self Args Self |
get_slots Args #{path: _},
call_next_method Self Args Self.

file_watch >> watch
| Self Effect |
get_slots Self #{path: Path, status: idle},
set_slot Self status starting,
new effect #{arguments: [Self, Path], operation: watch, provider: file} Effect.

file_watch >> watching
| Self |
get Self status starting,
set_slot Self status watching.

file_watch >> watch_failed
| Self Reason |
set_slot Self status #{reason: Reason, status: error}.

file_watch >> receive
| Self #{contents: #{status: ok, value: Contents}} |
set_slot Self contents Contents.

file_watch >> stop_watching
| Self Effect |
get Self status watching,
set_slot Self status stopping,
new effect #{arguments: [Self], operation: unwatch, provider: file} Effect.

file_watch >> stopped
| Self |
get Self status stopping,
set_slot Self status stopped.

file_watch >> stopped
| Self Reason |
set_slot Self status #{reason: Reason, status: error}.

file_watch >> stop_failed
| Self Reason |
set_slot Self status #{reason: Reason, status: error}.