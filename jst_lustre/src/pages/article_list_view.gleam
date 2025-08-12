import article/article.{type Article}
import birl
import components/ui
import gleam/list
import gleam/option.{None, Some}
import gleam/order
import gleam/string
import lustre/element.{type Element}
import session
import view/partials/article_partials as parts

pub fn view(
  articles: List(Article),
  sess: session.Session,
) -> List(Element(msg)) {
  let filtered_articles = case sess {
    session.Unauthenticated ->
      articles
      |> list.filter(fn(article) {
        case article.published_at {
          Some(_) -> True
          None -> False
        }
      })
    _ -> articles
  }

  let articles_elements =
    filtered_articles
    |> list.sort(fn(a, b) {
      case a.published_at, b.published_at {
        None, None -> string.compare(a.slug, b.slug)
        None, Some(_) -> order.Lt
        Some(_), None -> order.Gt
        Some(da), Some(db) -> birl.compare(db, da)
      }
    })
    |> list.map(parts.view_article_card)

  let header_section = [
    ui.flex_between(ui.page_title("Articles"), element.none()),
  ]

  let content_section = case articles_elements {
    [] -> [
      ui.empty_state(
        "No articles yet",
        case sess {
          session.Authenticated(_) ->
            "Ready to share your thoughts? Create your first article to get started."
          _ ->
            "No published articles are available yet. Check back later for new content!"
        },
        None,
      ),
    ]
    _ -> articles_elements
  }

  list.append(header_section, content_section)
}
