@source_text
#{
  super => value,
  ivars => [
    #{name => target},
    #{name => label, type => string},
    #{name => text, type => string},
    #{default => "al", name => grammar, type => string}
  ]
}.

source_text >> current
| Self Self |.

source_text >> validate_definition
| Self _Document |
current Self Current,
= Self Current.

source_text >> save_definition
| Self Text Edit |
new effect #{provider => source, operation => save, arguments => [Self, Text, Edit]} Effect,
on_completion Effect Outcome Finished (save_finished Edit Outcome),
await Finished.
