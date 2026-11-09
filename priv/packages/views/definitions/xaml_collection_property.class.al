@xaml_collection_property
#{super => xaml_property}.

xaml_collection_property >> xaml_content
| _Self Children Text |
lambda [Child, Part] Render (to_xaml Child Part),
map Children Render Parts,
join Parts Text.
