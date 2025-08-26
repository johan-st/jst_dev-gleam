import gleam/list
import lustre/attribute.{type Attribute} as attr
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/svg

pub type Icon {
  Close
  Menu
  Checkmark
  Logo
  LogoCustom(color_primary: String, color_secondary: String)
  LogoCustomWithBackground(
    color_primary: String,
    color_secondary: String,
    background_color: String,
  )
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
    Logo -> logo_svg(attr_given, "#be185d", "#be185d88", "transparent")
    LogoCustom(color_primary, color_secondary) ->
      logo_svg(attr_given, color_primary, color_secondary, "transparent")
    LogoCustomWithBackground(color_primary, color_secondary, background_color) ->
      logo_svg(attr_given, color_primary, color_secondary, background_color)
  }
}

fn logo_svg(
  attr_given attr_given: List(Attribute(msg)),
  color_primary_hex color_primary: String,
  secondary_color_hex secondary_color: String,
  background_color_hex background_color: String,
) -> Element(msg) {
  html.svg(
    list.append(attr_given, [
      attr.attribute("viewBox", "0 0 350 100"),
      attr.attribute("width", "300"),
      attr.attribute("height", "100"),
      attr.class("group cursor-pointer"),
    ]),
    [
      svg.polygon([
        attr.attribute("points", "60,0 350,0 310,100 20,100"),
        attr.attribute("fill", background_color),
        attr.class("drop-shadow-[0_0_3px_" <> background_color <> "]"),
      ]),
      svg.polygon([
        attr.attribute("points", "40,0 50,0 10,100 0,100"),
        attr.attribute("fill", secondary_color),
        attr.class("drop-shadow-[0_0_3px_" <> secondary_color <> "]"),
      ]),
      svg.polygon([
        attr.attribute("points", "60,0 70, 0 30,100 20,100"),
        attr.attribute("fill", color_primary),
        attr.class("drop-shadow-[0_0_3px_" <> color_primary <> "]"),
      ]),
      svg.text(
        [
          attr.attribute("x", "70"),
          attr.attribute("y", "65"),
          attr.attribute(
            "font-family",
            "ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, 'Liberation Mono', 'Courier New', monospace",
          ),
          attr.attribute("font-size", "60"),
          attr.attribute("font-weight", "bold"),
          attr.attribute("fill", color_primary),
          attr.class("drop-shadow-[0_0_3px_" <> color_primary <> "]"),
        ],
        "jst.dev",
      ),
    ],
  )
}
