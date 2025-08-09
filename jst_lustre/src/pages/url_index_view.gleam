import lustre/element.{type Element}
import partials/article_partials as parts

pub fn view(list: Element(msg)) -> List(Element(msg)) {
  [
    parts.view_title("URL Shortener", "url-shortener"),
    parts.view_simple_paragraph("Create and manage short URLs for easy sharing."),
    list,
  ]
}

