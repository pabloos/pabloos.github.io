+++
title = "Semantic middlewares"
date = 2022-11-20T17:23:59+01:00
aliases = ["/backend/middleware/"]
+++

### Piping the request

The middleware pattern is an ubiquitous software concept that help us to decoulpe a request process in stages the same way [pipeline pattern](/posts/pipelines/) does. His monoidal nature grants ease of composition, which allow us to reuse any of these stages with other proceses. Moreover, this behaviour arises a declarative way to define our service architecture in semantic terms.

This post will cover the foundations of this mechanism in the HTTP ecosystem, providing some uses to atomize our handlers, and finally showing up the benefits of this approach to define our architecture.

![pipelines](/middleware/pipeline2.png)

Because of its simple and concise syntax, Go is a good language to draft some of the capabilities this pattern brings to our services. It's a good match, since backend dev is his mainstream domain core, too. But also it's an exotic choice to talk from an algebraic point of view. And a funny one, I hope.

His most common implementation is based on the [Handler interface in the standard library](https://pkg.go.dev/net/http#Handler). In that sense, a middleware is just a closure that links handlers:

```go
import _ "net/http"

type Middleware func(Handler) Handler

func Nop(next Handler) Handler {
    return HandlerFunc(func(res ResponseWriter, req *Request) {
        // some logic ...

        next.ServeHTTP(res, req) // continue to the next stage
    })
}
```

Because of our needs, we're going to popule it with some dependencies. To make it possible middlewares can be built through objects or closures. As I said in a [previous post](http://localhost:1313/languages/one2one/), I prefer the last one in order to embrace a more functional fashion. That's it: a closure that closes a closure:

```go
func Auth(authz infra.Authz) mux.MiddlewareFunc {
	auth.Init()

	return func(next Handler) Handler {
		return HandlerFunc(func(res ResponseWriter, req *Request) {
			jwt := req.Headers().Get("Authorization")
			
			authz.Check(jwt)
		})
	}
}
```

### Connecting

Furthermore of being linked, our middleware gets better if we could *connect* them each other sharing data. For this purpose we use the request's context, which carries the values in his inner map.

```go
func injector(next Handler) Handler {
    return HandlerFunc(func(res ResponseWriter, req *Request) {
		ctx := saveNumber(req.Context(), 22)

        next.ServeHTTP(res, req.WithContext(ctx))
    })
}

func receiver(next Handler) Handler {
    return HandlerFunc(func(res ResponseWriter, req *Request) {
		number := GetNumber(ctx)

		// ...
	})
}
```

The most ergonomic way is to use a setter and a getter for retrieve data from the context:

```go
type IdKey struct{}

func saveNumber(ctx context.Context, number int) context.Context {
	return context.WithValue(ctx, IdKey{}, number)
}

func getNumber(ctx context.Context) int {
	return ctx.Value(IdKey{}).(int)
}
```

![pipelines](/middleware/ctx2.png)

You can take advantage of the middleware signature and inject a handler to test his result catching ctx values.

```go
func Test_Injector_Middleware(t *testing.T) {
	handler := injector(test(t))

	req, _ := NewRequest(MethodGet, "", nil)

	handler.ServeHTTP(httptest.NewRecorder(), req)
}

func test(t *testing.T) Handler {
	return HandlerFunc(func(res ResponseWriter, req *Request) {
		number := getNumber(req.Context())

		if number != 22 {
			t.Fatal("not expected number")
		}
	})
}
```

For test other side effects in middlewares is a good practice to define parametrs as interfaces in order to make dependency injection testable.


### Composing

As I said before, middlewares could be seen as an instance of the monoid class: there's an operation that, given two middlewares, produces a third one. We will call this operation *chain*. Chain also respects the associavity rule, so you could compose more than two middlewares at the same time:

![asociativity](/middleware/associativity.png)

For the sake of ergonomy all this three formulas will be mixed in the same function

```go
func Chain(mids ...Middleware) Middleware {
	return func(handler Handler) Handler {
		if len(mids) < 1 {
			return handler
		}

		for i := len(mids) - 1; i >= 0; i-- {
			handler = mids[i](handler)
		}

		return handler
	}
}
```

Just a little bit more of category theory: obviously the id element in the monoid is the middleware with no logic inside:

```go
func id(next Handler) Handler {
	return HandlerFunc(func(res ResponseWriter, req *Request) {
		next.ServeHTTP(res, req)
	})
}
```

![pipelines](/middleware/id.png)

<!-- This behaviour requires a function that chains these middlewares in a particular order to work propertly: -->

### Packaging

![pipelines](/middleware/chain.png)

There's so many routing libraries out there, but they all work similary. Here's an example with the gorilla/mux API:

```go
router := mux.NewRouter()

handler := chain(auth,validate,bind)(format)

router.Handle("/gifts/{id}", handler)

http.Handle("/", r)
```

### Architecture matrix

From a DDD perspective, you will find yourself writing two kinds of middlewares definitions:

- infraestructure: authorization, logging, caching ...
- domain: middlewares that yo need to keep inside the endpoints domain

![pipelines](/middleware/matrix5.png)

### Use cases

- #### dynamic dependency injection

```go
func Stores(db *gorm.DB) Middleware {
	return func(next Handler) Handler {
		return HandlerFunc(func(res ResponseWriter, req *Request) {
			ctx := context.WithValue(req.Context(), DbKey{}, db)

			next.ServeHTTP(res, req.WithContext(ctx))
		})
	}
}
```

- #### bind-like pattern

With that in mind it's simple to bring route-object binding to your REST API, [somehow laravel does](https://laravel.com/docs/9.x/routing#implicit-binding):

```go
func Bind(table string) Middleware {
	return func(next Handler) Handler {
		return HandlerFunc(func(res ResponseWriter, req *Request) {
			id := mux.Vars(req)["id"]

            object := getObject(id)

            ctx = context.WithValue(req.Context(), BindKey{}, object)

            next.ServeHTTP(res, req.WithContext(ctx))
		})
	}
}
```

And also collections for lists endpoints:

```go
func BindCollection(table string) Middleware {
	return func(next Handler) Handler {
		return HandlerFunc(func(res ResponseWriter, req *Request) {
            ctx := req.Context()

            collection := getTable(table)

            ctx = context.WithValue(ctx, CollectionKey{}, collection)

            next.ServeHTTP(res, req.WithContext(ctx))
		})
	}
}
```

- #### validators

![pipelines](/middleware/validate.png)

Define a function that can check errors in an incoming request is easy:

```go
type Checker func(*Request) error
```

So, implementing a middleware for validation is as easy as define a middleware that just iterates over a collecition of checks:

```go
func Validate(checks ...Check) Middleware {
	return func(next Handler) Handler {
		return HandlerFunc(func(res ResponseWriter, req *Request) {
			for _, check := range checks {
				err := check(req)
				if err != nil {
					Error(res, err.Error(), StatusBadRequest)
					return
				}
			}

			next.ServeHTTP(res, req)
		})
	}
}
```

Even better, we could define a middleware builder based on the status error you want to return, and predefine some instances for to check conditions, validate input data, rate limiters ...

```go
func BuildValidation(status int) ValidateFunc {
	return func(checks ...Check) Middleware {
		// ...

			if err != nil {
				http.Error(res, err.Error(), status)
				return
			}
	}
}

var Meet = BuildValidation(http.StatusPreconditionFailed)
var Limit = BuildValidation(http.StatusTooManyRequests)
var Validate = BuildValidation(http.StatusBadRequest)
var Authenticate = BuildValidation(http.StatusUnauthorized)
var Authorize = BuildValidation(http.StatusForbidden)
```

### [My library](https://github.com/pabloos/go-http-middleware)
In order to avoid boilerplate code in every http backend project, I've created a [library](https://github.com/pabloos/go-http-middleware) that let you reuse some of the definitions I discuss before:

- middleware type
- chain function
- check type
- validate middleware
- condition middleware
