import gleam/uri

pub type Content {
  Text(String)
  Block(List(Content))
  Heading(String)
  Paragraph(List(Content))
  Link(uri.Uri, String)
  LinkExternal(uri.Uri, String)
  Image(uri.Uri, String)
  List(List(Content))
  Unknown(String)
}
