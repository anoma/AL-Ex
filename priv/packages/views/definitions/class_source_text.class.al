@class_source_text
#{super => source_text, ivars => [#{name => source_selector}]}.

class_source_text >> current
| Self Source |
get_slots Self #{target => Target, source_selector => Selector},
send Target Selector [Source].

class_source_text >> save
| Self Text Edit |
get Self source_selector definition_source,
save_definition Self Text Edit.

class_source_text >> save
| Self Text Edit |
get_slots Self #{source_selector => comment_source, target => Target},
current Self Self,
set_slot Target comment Text,
saved Edit Self Text,
save_finished Edit #{status => ok, value => Target}.

class_source_text >> validate_definition
| Self Document |
get_slots Self #{source_selector => definition_source, target => Target},
get_slots Document #{header => Header, methods => []},
get_slots Header #{kind => class, name => Target},
call_next_method Self Document.