---
title: Blog
slug: blog
public: false
tags:
  - blog
---

## Datastructures

### Article

```go
type Article struct {
	Slug      string
	Revision  int
	Title     string
	Subtitle  string
	Leading   string
	Content   []ArticleContent
}

type ArticleContent struct {
	Type    ArticleContentType
	Content ArticleContent
}


type ArticleContentType string

const (
	ArticleContentTypeHeading   ArticleContentType = "heading"
	ArticleContentTypeParagraph ArticleContentType = "paragraph"
	ArticleContentTypeText      ArticleContentType = "text"
	ArticleContentTypeLink      ArticleContentType = "link"
	ArticleContentTypeCode      ArticleContentType = "code"
)


```

### ArticleRevision

