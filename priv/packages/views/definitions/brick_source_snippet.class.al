@brick_source_snippet
#{
  super => brick_editable_snippet,
  ivars => [#{name => source_record, type => source_text}]
}.

brick_source_snippet >> init
| Self Args Self |
get Args source_record Source,
new source_edit #{source_record => Source} Edit,
put Args edit Edit Fields,
call_next_method Self Fields Self.
