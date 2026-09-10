Extension {
  #name : :composable_widget,
  #superclass : [:renderable]
}

:composable_widget >> :rendering_package, [_self, :widget_rendering] [
  pass()
]
