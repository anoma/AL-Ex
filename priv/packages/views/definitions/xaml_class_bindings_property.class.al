@xaml_class_bindings_property
#{super => xaml_property}.

xaml_class_bindings_property >> render
| Self Bindings Text |
findall Part Parts {
  get Bindings Name Binding,
  atom_string Name Raw,
  xml_escape Self Raw Escaped,
  to_xaml Binding Content,
  format "<Classes.~a>~a</Classes.~a>" [Escaped, Content, Escaped] Part
},
join Parts Text.