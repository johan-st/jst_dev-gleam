import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lustre/attribute as attr
import lustre/element.{type Element}
import lustre/element/html
import utils/jot.{
  type Container, type Destination, type Document, type Inline, Code, Codeblock,
  Emphasis, Heading, Image, Linebreak, Link, Paragraph, Reference, Strong, Text,
  ThematicBreak, Url, parse,
}

type Refs =
  Dict(String, String)

/// Convert a string of Djot into lustre html elements.
pub fn to_lustre(djot: String) {
  djot
  |> parse
  |> document_to_lustre
}

/// Convert a Djot document (normally comes from the parse fn)
/// into lustre html elements.
pub fn document_to_lustre(document: Document) {
  list.reverse(
    containers_to_lustre(document.content, document.references, [element.none()]),
  )
}

fn containers_to_lustre(
  containers: List(Container),
  refs: Refs,
  elements: List(Element(msg)),
) {
  case containers {
    [] -> elements
    [container, ..rest] -> {
      let elements = container_to_lustre(elements, container, refs)
      containers_to_lustre(rest, refs, elements)
    }
  }
}

fn container_to_lustre(
  elements: List(Element(msg)),
  container: Container,
  refs: Refs,
) {
  let element = case container {
    Paragraph(attrs, inlines) -> {
      html.p(
        attributes_to_lustre(attrs, [attr.class("pt-8")]),
        inlines_to_lustre([], inlines, refs),
      )
    }
    Heading(attrs, level, inlines) -> {
      case level {
        1 ->
          html.h1(
            attributes_to_lustre(attrs, [
              attr.class("text-3xl text-pink-700 font-light"),
            ]),
            inlines_to_lustre([], inlines, refs),
          )
        2 ->
          html.h2(
            attributes_to_lustre(attrs, [
              attr.class("text-2xl text-pink-600 font-light pt-16"),
            ]),
            inlines_to_lustre([], inlines, refs),
          )
        3 ->
          html.h3(
            attributes_to_lustre(attrs, [
              attr.class("text-xl text-pink-600 font-light pt-12"),
            ]),
            inlines_to_lustre([], inlines, refs),
          )
        4 ->
          html.h4(
            attributes_to_lustre(attrs, [
              attr.class("text-lg text-pink-600 font-light pt-8"),
            ]),
            inlines_to_lustre([], inlines, refs),
          )
        5 ->
          html.h5(
            attributes_to_lustre(attrs, [
              attr.class("text-base text-pink-600 font-light pt-6"),
            ]),
            inlines_to_lustre([], inlines, refs),
          )
        _ ->
          html.h6(
            attributes_to_lustre(attrs, [
              attr.class("text-sm text-pink-600 font-light pt-4"),
            ]),
            inlines_to_lustre([], inlines, refs),
          )
      }
    }
    Codeblock(attrs, language, content) -> {
      html.pre(attributes_to_lustre(attrs, [attr.class("pt-8")]), [
        html.code(
          case language {
            Some(lang) -> [
              attr.class(
                "language-"
                <> lang
                <> " bg-zinc-800 p-4 rounded-md block overflow-x-auto",
              ),
            ]
            None -> [
              attr.class("bg-zinc-800 p-4 rounded-md block overflow-x-auto"),
            ]
          },
          [html.text(content)],
        ),
      ])
    }
    ThematicBreak -> {
      html.hr([attr.class("border-zinc-700 my-8")])
    }
  }
  [element, ..elements]
}

fn inlines_to_lustre(
  elements: List(Element(msg)),
  inlines: List(Inline),
  refs: Refs,
) {
  case inlines {
    [] -> elements
    [inline, ..rest] -> {
      elements
      |> inline_to_lustre(inline, refs)
      |> inlines_to_lustre(rest, refs)
    }
  }
}

fn inline_to_lustre(
  elements: List(Element(msg)),
  inline: Inline,
  refs: Dict(String, String),
) {
  case inline {
    Linebreak -> [html.br([])]
    Text(text) -> [html.text(text)]
    Strong(inlines) -> {
      [
        html.strong(
          [attr.class("font-bold")],
          inlines_to_lustre(elements, inlines, refs),
        ),
      ]
    }
    Emphasis(inlines) -> {
      [
        html.em(
          [attr.class("italic")],
          inlines_to_lustre(elements, inlines, refs),
        ),
      ]
    }
    Link(text, destination) -> {
      [
        html.a(
          [
            attr.href(destination_attribute(destination, refs)),
            attr.class("text-pink-700 hover:underline cursor-pointer"),
          ],
          inlines_to_lustre(elements, text, refs),
        ),
      ]
    }
    Image(text, destination) -> {
      [
        html.img([
          attr.src(destination_attribute(destination, refs)),
          attr.alt(take_inline_text(text, "")),
          attr.class("max-w-full h-auto rounded-lg shadow-lg mt-8"),
        ]),
      ]
    }
    Code(content) -> {
      [
        html.code(
          [attr.class("bg-zinc-800 px-1 py-0.5 rounded text-sm font-mono")],
          [html.text(content)],
        ),
      ]
    }
  }
}

fn destination_attribute(destination: Destination, refs: Refs) {
  case destination {
    Url(url) -> url
    Reference(id) ->
      case dict.get(refs, id) {
        Ok(url) -> url
        Error(Nil) -> ""
      }
  }
}

fn take_inline_text(inlines: List(Inline), acc: String) -> String {
  case inlines {
    [] -> acc
    [first, ..rest] ->
      case first {
        Text(text) | Code(text) -> take_inline_text(rest, acc <> text)
        Strong(inlines) | Emphasis(inlines) ->
          take_inline_text(list.append(inlines, rest), acc)
        Link(nested, _) | Image(nested, _) -> {
          let acc = take_inline_text(nested, acc)
          take_inline_text(rest, acc)
        }
        Linebreak -> {
          take_inline_text(rest, acc)
        }
      }
  }
}

fn attributes_to_lustre(attributes: Dict(String, String), lustre_attributes) {
  attributes
  |> dict.to_list
  |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  |> list.fold(lustre_attributes, fn(lustre_attributes, pair) {
    [attr.attribute(pair.0, pair.1), ..lustre_attributes]
  })
}
