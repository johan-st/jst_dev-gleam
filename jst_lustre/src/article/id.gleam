pub opaque type ArticleId {
  ArticleId(id: String)
}

pub fn from_string(id: String) -> ArticleId {
  ArticleId(id)
}

pub fn to_string(id: ArticleId) -> String {
  id.id
}
