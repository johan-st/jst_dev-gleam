import lustre/attribute as attr
import lustre/element.{type Element}
import lustre/element/html

/// App layout wrapper for page content
pub fn view(content: List(Element(msg))) -> Element(msg) {
  html.main(
    [
      attr.class(
        "max-w-screen-md mx-auto px-4 sm:px-6 md:px-10 py-6 sm:py-8 md:py-10",
      ),
    ],
    content,
  )
}

