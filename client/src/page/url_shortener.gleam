import common.{type UrlShort}

pub type Model {
  Form(String)
  Saving(UrlShort)
  Saved(UrlShort)
  Error(UrlShort, String)
}
