@phlow_class_source
#{super => phlow_xaml, ivars => [#{name => target}, #{name => source_selector}]}.

phlow_class_source >> to_map
| Self Map |
get_slots Self #{source_selector => Selector, target => Target},
send Target Selector [Source],
new brick_source_snippet #{source_record => Source} Brick,
put Self brick Brick View,
call_next_method View Map,
cut.
