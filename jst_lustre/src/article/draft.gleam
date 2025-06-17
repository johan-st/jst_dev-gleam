import article/content.{type Content}

pub opaque type Draft {
  DraftV1(
    saving: Bool,
    slug: String,
    title: String,
    subtitle: String,
    leading: String,
    content: List(Content),
  )
}

pub fn new(slug, title, subtitle, leading, content) {
  DraftV1(saving: False, slug:, title:, subtitle:, leading:, content:)
}

pub fn is_saving(draft) {
  case draft {
    DraftV1(saving:, slug: _, title: _, subtitle: _, leading: _, content: _) ->
      saving
  }
}

pub fn slug(draft) {
  case draft {
    DraftV1(saving: _, slug:, title: _, subtitle: _, leading: _, content: _) ->
      slug
  }
}

pub fn title(draft) {
  case draft {
    DraftV1(saving: _, slug: _, title:, subtitle: _, leading: _, content: _) ->
      title
  }
}

pub fn subtitle(draft) {
  case draft {
    DraftV1(saving: _, slug: _, title: _, subtitle:, leading: _, content: _) ->
      subtitle
  }
}

pub fn leading(draft) {
  case draft {
    DraftV1(saving: _, slug: _, title: _, subtitle: _, leading:, content: _) ->
      leading
  }
}

pub fn content(draft) {
  case draft {
    DraftV1(saving: _, slug: _, title: _, subtitle: _, leading: _, content:) ->
      content
  }
}

pub fn set_slug(draft, slug) {
  case draft {
    DraftV1(saving, _, title, subtitle, leading, content) ->
      DraftV1(saving, slug, title, subtitle, leading, content)
  }
}

pub fn set_title(draft, title) {
  case draft {
    DraftV1(saving, slug, _, subtitle, leading, content) ->
      DraftV1(saving, slug, title, subtitle, leading, content)
  }
}

pub fn set_subtitle(draft, subtitle) {
  case draft {
    DraftV1(saving, slug, title, _, leading, content) ->
      DraftV1(saving, slug, title, subtitle, leading, content)
  }
}

pub fn set_leading(draft, leading) {
  case draft {
    DraftV1(saving, slug, title, subtitle, _, content) ->
      DraftV1(saving, slug, title, subtitle, leading, content)
  }
}

pub fn set_content(draft, content) {
  case draft {
    DraftV1(saving, slug, title, subtitle, leading, _) ->
      DraftV1(saving, slug, title, subtitle, leading, content)
  }
}

pub fn set_saving(draft, saving) {
  case draft {
    DraftV1(_, slug, title, subtitle, leading, content) ->
      DraftV1(saving, slug, title, subtitle, leading, content)
  }
}
