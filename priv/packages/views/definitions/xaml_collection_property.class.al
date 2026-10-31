@xaml_collection_property
#{super => xaml_property}.

xaml_collection_property >> xaml_content
| Self Text |
slot_value Self Children,
lambda [Child, Part] Render (to_xaml Child Part),
map Children Render Parts,
join Parts Text.
