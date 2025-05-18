import article/content.{type Content}

pub type Draft {
  Draft(
    saving: Bool,
    slug: String,
    title: String,
    subtitle: String,
    leading: String,
    content: List(Content),
  )
}
