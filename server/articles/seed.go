package articles

import "github.com/google/uuid"

// NatsAllTheWayDown returns an Article containing a narrative about adopting NATS as a messaging system, including reflections on its impact and usage in Go applications.
func NatsAllTheWayDown() Article {
	return Article{
		StructVersion: 1,
		Id:            uuid.New(),
		Slug:          "nats-all-the-way-down",
		Rev:           10,
		Title:         "NATS all the way down",
		Subtitle:      "..or, how to replace your stack with one tool.",
		Leading:       "I've fallen in love several times these last few years since I started writing code for a living. A few highlights are Docker, Elm, functional programming, Go, simple and portable file formats, my son, markdown, gleam and now NATS. Each infatuation has taught me something important about a technology and usually also about myself.",
		Content: `## In the beginning..

Just like many of my adventures the last few years, it started with me reading the docs for some project I recently heard about. This time it was NATS. The more I read, the more I wanted to explore the patterns NATS and systems like it enable.

ASIDE: NATS is a messaging system that allows you to send and receive messages between different systems. It's a bit like email, but it's designed for the cloud and for modern systems. In go applications I tend to embed the server in my library and use nats as an in-process messaging system.

## Sadness ensues

When realizing how much of the backend can be replaced by a nats server I got a bit disheartened.. I enjoy writing go servers.. but maybe the sane choice is to use synadia and just add whatever pieces are not available there..

For now I will use the nats server in my go application but I will probably offload a lot of logic to the client. *Gleam* really is a delightful language to write!

[<-- back link test](/articles)`,
	}
}

// TestArticle returns a sample Article struct demonstrating various content types using Djot markup.
func TestArticle() Article {
	return Article{
		StructVersion: 1,
		Id:            uuid.New(),
		Slug:          "test-article",
		Rev:           9,
		Title:         "Test Article",
		Subtitle:      "..or, fitting all types of content into a single article",
		Leading:       "This is a test article. The lead of a test article actually contains the same text as the title. This is a test article. The lead of a test article actually contains the same text as the title. This is a test article. The lead of a test article actually contains the same text as the title.",
		Content: `## list of Links

- [404 page, internal link](/404_not-found)
- [Gleam, external link](https://gleam.run)

This is a paragraph with a list inside it. It is [here](#booop) and this is the continuation of the paragraph.

## Lists of paragraphs and lists

- Item 1

- Item 2

- Item 3

  - Item 3.1
  - Item 3.2
  - Item 3.3`,
	}
}

// 		Content: Content{
// 			Type: ContentBlock,
// 			Content: []Content{
// 					{
// 						Type: ContentText,
// 						Text: "In the beginning..",
// 					},
// 				},
// 			},
// 			{
// 				Type: ContentParagraph,
// 				Content: []Content{
// 					{
// 						Type: ContentText,
// 						Text: "Just like many of my adventures the last few years, it started with me reading the docs for some project I recently heard about. This time it was NATS. The more I read, the more I wanted to explore the patterns NATS and systems like it enable.",
// 					},
// 				},
// 			},
// 			{
// 				Type: ContentParagraph,
// 				Content: []Content{
// 					{
// 						Type: ContentText,
// 						Text: "ASIDE: NATS is a messaging system that allows you to send and receive messages between different systems. It's a bit like email, but it's designed for the cloud and for modern systems. In go applications I tend to embed the server in my library and use nats as an in-process messaging system.",
// 					},
// 				},
// 			},
// 			{
// 				Type: ContentHeading,
// 				Content: []Content{
// 					{
// 						Type: ContentText,
// 						Text: "Sadness ensues",
// 					},
// 				},
// 			},
// 			{
// 				Type: ContentParagraph,
// 				Content: []Content{
// 					{
// 						Type: ContentText,
// 						Text: "When realizing how much of the backend can be replaced by a nats server I got a bit disheartened.. I enjoy writing go servers.. but maybe the sane choice is to use synadia and just add whatever pieces are not available there..",
// 					},
// 				},
// 			},
// 			{
// 				Type: ContentParagraph,
// 				Content: []Content{
// 					{
// 						Type: ContentText,
// 						Text: "For now I will use the nats server in mh go application but I will probably offload a lot of logic to the client. `Gleam` really is a delightfull language to write!",
// 					},
// 				},
// 			},
// 		},
// 	}
// }
