import gleam/list
import lustre/attribute.{type Attribute} as attr
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/svg

pub type Icon {
  Close
  Menu
  Checkmark
}

pub fn view(
  attributes attr_given: List(Attribute(msg)),
  icon icon: Icon,
) -> Element(msg) {
  case icon {
    Close ->
      html.svg(
        list.append(attr_given, [
          attr.attribute("viewBox", "0 0 24 24"),
          attr.attribute("fill", "none"),
          attr.attribute("stroke", "currentColor"),
          attr.attribute("stroke-width", "2"),
          attr.attribute("stroke-linecap", "round"),
          attr.attribute("stroke-linejoin", "round"),
        ]),
        [
          svg.line([
            attr.attribute("x1", "18"),
            attr.attribute("y1", "6"),
            attr.attribute("x2", "6"),
            attr.attribute("y2", "18"),
          ]),
          svg.line([
            attr.attribute("x1", "6"),
            attr.attribute("y1", "6"),
            attr.attribute("x2", "18"),
            attr.attribute("y2", "18"),
          ]),
        ],
      )
    Menu ->
      html.svg(
        list.append(attr_given, [
          attr.attribute("viewBox", "0 0 24 24"),
          attr.attribute("fill", "none"),
          attr.attribute("stroke", "currentColor"),
          attr.attribute("stroke-width", "2"),
          attr.attribute("stroke-linecap", "round"),
          attr.attribute("stroke-linejoin", "round"),
        ]),
        [
          svg.line([
            attr.attribute("x1", "3"),
            attr.attribute("y1", "6"),
            attr.attribute("x2", "21"),
            attr.attribute("y2", "6"),
          ]),
          svg.line([
            attr.attribute("x1", "3"),
            attr.attribute("y1", "12"),
            attr.attribute("x2", "21"),
            attr.attribute("y2", "12"),
          ]),
          svg.line([
            attr.attribute("x1", "3"),
            attr.attribute("y1", "18"),
            attr.attribute("x2", "21"),
            attr.attribute("y2", "18"),
          ]),
        ],
      )
    Checkmark ->
      html.svg(
        list.append(attr_given, [
          attr.attribute("viewBox", "0 0 24 24"),
          attr.attribute("fill", "none"),
          attr.attribute("stroke", "currentColor"),
          attr.attribute("stroke-width", "2"),
          attr.attribute("stroke-linecap", "round"),
          attr.attribute("stroke-linejoin", "round"),
        ]),
        [svg.polyline([attr.attribute("points", "20,6 9,17 4,12")])],
      )
  }
}
