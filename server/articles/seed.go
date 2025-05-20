package articles

// NatsAllTheWayDown returns an Article containing a narrative about adopting NATS as a messaging system, including reflections on its impact and usage in Go applications.
func NatsAllTheWayDown() Article {
	return Article{
		StructVersion: 1,
		Slug:          "nats-all-the-way-down",
		Rev:           10,
		Title:         "Nats All The Way Down",
		Subtitle:      "..or, how to replace your stack with one tool.",
		Leading:       "I've fallen in love several times these last few years since I started writing code for a living. A few highlights are Docker, Elm, functional programming, Go, simple and portable file formats, my son, markdown, gleam and now NATS. Each infatuation has taught me something important about a technology and usually also about myself.",
		Content: []Content{
			Block(
				Heading("In the beginning.."),
				Paragraph(
					Text("Just like many of my adventures the last few years, it started with me reading the docs for some project I recently heard about. This time it was NATS. The more I read, the more I wanted to explore the patterns NATS and systems like it enable."),
				), Paragraph(
					Text("ASIDE: NATS is a messaging system that allows you to send and receive messages between different systems. It's a bit like email, but it's designed for the cloud and for modern systems. In go applications I tend to embed the server in my library and use nats as an in-process messaging system."),
				),
			),
			Block(
				Heading("Sadness ensues"),
				Paragraph(
					Text("When realizing how much of the backend can be replaced by a nats server I got a bit disheartened.. I enjoy writing go servers.. but maybe the sane choice is to use synadia and just add whatever pieces are not available there.."),
				),
				Paragraph(

					Text("For now I will use the nats server in mh go application but I will probably offload a lot of logic to the client. `Gleam` really is a delightfull language to write!"),
				),
			),
			Link("/articles", "<-- back link test"),
		},
	}
}

// TestArticle returns a sample Article struct demonstrating various content types, including headings, paragraphs, internal and external links, and nested lists.
func TestArticle() Article {
	return Article{
		StructVersion: 1,
		Slug:          "test-article",
		Rev:           9,
		Title:         "Test Article",
		Subtitle:      "..or, fitting all types of content into a single article",
		Leading:       "This is a test article. The lead of a test article actually contains the same text as the title. This is a test article. The lead of a test article actually contains the same text as the title. This is a test article. The lead of a test article actually contains the same text as the title.",
		Content: []Content{
			Block(
				Heading("list of Links"),
				List(
					Link("/404_not-found", "404 page, internal link"),
					LinkExternal("https://gleam.run", "Gleam, external link"),
				),
			),
			Block(
				Paragraph(
					Text("This is a paragraph with a list inside it. It is "),
					Link("#booop", "here"),
					Text(". and this is the continuation of the paragraph."),
				),
				Heading("Lists of paragraphs and lists"),
				List(
					Paragraph(Text("Item 1")),
					Paragraph(Text("Item 2")),
					Paragraph(Text("Item 3")),
					List(
						Text("Item 3.1"),
						Text("Item 3.2"),
						Text("Item 3.3"),
					),
				),
			),
		},
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
