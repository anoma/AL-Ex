@class_up_to_filter
#{super => method_filter, ivars => [#{name => target}, #{name => side}]}.

class_up_to_filter >> init
| Self Args Self |
get_slots Args #{target => Target, side => Side},
reachable_classes [Target] [] Classes,
new filter_choice #{choices => Classes} Input,
lambda [Index, Source] Match {
  get Source side Side -> {
    get Source owner Owner,
    length Prefix Index,
    concat Prefix [Last . _Rest] Classes,
    concat Prefix [Last] Included,
    member Included Owner
  } ; pass
},
put Args input Input WithInput,
put WithInput predicate Match Fields,
call_next_method Self Fields Self.