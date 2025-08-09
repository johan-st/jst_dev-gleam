import lustre/element.{type Element}
import partials/article_partials as parts

pub fn view() -> List(Element(msg)) {
  [
    parts.view_title("About", "about"),
    parts.view_simple_paragraph(
      "I'm a software developer and a writer. I'm also a father and a husband. 
      I'm also a software developer and a writer. I'm also a father and a 
      husband. I'm also a software developer and a writer. I'm also a father 
      and a husband. I'm also a software developer and a writer. I'm also a 
      father and a husband.",
    ),
    parts.view_simple_paragraph(
      "If you enjoy these glimpses into my mind, feel free to come back
       semi-regularly. But not too regularly, you creep.",
    ),
  ]
}

