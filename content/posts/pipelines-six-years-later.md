+++
title = "Pipelines, six years later"
description = "A pipeline I wrote in 2020 ended with a TODO list that never got done. Generics were only half of the reason."
date = 2026-09-14
aliases = ["/concurrency/pipelines-six-years-later/"]

[extra]
image = "og/pipelines-six-years-later.png"
+++

Six years ago I wrote [Pipelines](/posts/pipelines/). The idea wasn't mine; I took it from [Go Concurrency Patterns: Pipelines and cancellation](https://go.dev/blog/pipelines), Sameer Ajmani's 2014 article. What I was trying to add was standardisation: take something everyone was hand-rolling and turn it into a thing you could reuse instead of rebuilding it each time. That's why the post works its way toward a type per concept, an injected transformation, generated stages, and finally a `Pipeline` struct with an `Exec` method. I wanted to turn it into a library.

It closed with a TODO list:

- fan in/out
- cancellation
- when to use buffered channels
- errors

Two different things kept that list from getting done, and for years I told myself it was only the first one.

### What I couldn't write down

Here is the type the whole post is based on:

```go
type pipe <-chan int
```

`int`. Not a type parameter, because Go didn't have them until 1.18. A pipeline library needs to say *a stage takes an `I` and produces an `O`*, and in 2020 there was no way to say that. The options were `interface{}` with a type assertion at every stage boundary, code generation, or picking one concrete type and pretending it stood for all of them. I picked `int` and moved on, because the alternatives make the thing you're trying to standardise worse than the hand-rolled version.

So the library was put on hold, which was fair enough. Then generics landed in March 2022 and I did what a lot of people did: waited to see whether the community would actually adopt them or treat them as a footnote. By the time that question had clearly resolved, the post had been sitting in a drawer for long enough that reopening it felt like archaeology.

### What the sketch actually built

Strip the standardisation away and what's underneath is a chain of functions, each taking a channel and returning a channel. Every one of them looked like this (read a value, transform it, send it on):

```go
func firstStage(in pipe) pipe {
    out := make(chan int)

    go func() {
        for n := range in {
            out <- n * n
        }
        close(out)
    }()

    return out
}
```

To run a pipeline you nested them: `end(thirdStage(secondStage(firstStage(source(...)))))`. Each call starts a goroutine and hands back the channel it writes into, so the nesting builds a chain of goroutines joined by channels.

<svg viewBox="0 0 720 150" role="img" style="width:100%;height:auto;max-width:720px;display:block;margin:1.75rem auto" fill="none" stroke="currentColor" font-family="ui-monospace, SFMono-Regular, Menlo, monospace" font-size="12">
  <title>2020: five goroutines chained by unbuffered channels, one value in flight on each</title>
  <text x="0" y="12" stroke="none" fill="currentColor" font-size="11" opacity="0.7">2020: one goroutine per stage</text>
  <g stroke-width="1.2">
    <rect x="1" y="34" width="92" height="38" rx="2"/>
    <rect x="145" y="34" width="92" height="38" rx="2"/>
    <rect x="289" y="34" width="92" height="38" rx="2"/>
    <rect x="433" y="34" width="92" height="38" rx="2"/>
    <rect x="577" y="34" width="92" height="38" rx="2"/>
  </g>
  <g stroke="none" fill="currentColor" text-anchor="middle">
    <text x="47" y="58">source</text>
    <text x="191" y="58">stage 1</text>
    <text x="335" y="58">stage 2</text>
    <text x="479" y="58">stage 3</text>
    <text x="623" y="58">end</text>
  </g>
  <g stroke-width="1.2">
    <path d="M93 53 H139"/><path d="M133 49 l6 4 -6 4"/>
    <path d="M237 53 H283"/><path d="M277 49 l6 4 -6 4"/>
    <path d="M381 53 H427"/><path d="M425 49 l6 4 -6 4"/>
    <path d="M525 53 H571"/><path d="M569 49 l6 4 -6 4"/>
  </g>
  <g fill="currentColor" stroke="none">
    <circle cx="116" cy="53" r="3"/>
    <circle cx="260" cy="53" r="3"/>
    <circle cx="404" cy="53" r="3"/>
    <circle cx="548" cy="53" r="3"/>
  </g>
  <g stroke="none" fill="currentColor" font-size="10" opacity="0.75" text-anchor="middle">
    <text x="116" y="88">chan int</text>
    <text x="260" y="88">chan int</text>
    <text x="404" y="88">chan int</text>
    <text x="548" y="88">chan int</text>
  </g>
  <text x="0" y="122" stroke="none" fill="currentColor" font-size="11" opacity="0.7">5 goroutines · 1 value in flight per channel · throughput = the slowest stage</text>
  <text x="0" y="138" stroke="none" fill="currentColor" font-size="11" opacity="0.7">widening a stage means writing a merge, not changing a number</text>
</svg>

Count the goroutines in that picture and you get five. Now count the values moving through it at any instant, and you also get five, one sitting on each channel. The channels are unbuffered, so a stage can't take a second value until the next stage has taken the first off its hands. The whole chain moves in lock-step, at the speed of whichever stage is slowest.

### The list was already answered

Every item on my TODO list is a section heading in the article I took the shape from. Fan-out and fan-in, with a `merge` that uses a `sync.WaitGroup`. Cancellation, as a `done` channel the caller closes and every stage selects on. Leaks, under "Stopping short". Buffered channels and a bounded pool. All of it published, with working code, six years before I listed the four of them as future work.

I had taken the skeleton and left behind the machinery that makes it work outside a demo. Not out of laziness: in this design every one of those answers is wired into the stages by hand, and re-wired whenever the pipeline changes. Fan-out isn't a number you raise, it's a `merge` plus a decision about ordering, written again for each pipeline. Cancellation is a `done` channel threaded into every stage and selected on at every send. Miss one and you have a leak that surfaces under load, months later.

Four items, four rewrites, every one of them touching every stage. Not impossible, then. The cause underneath all four is the same: the stages own the concurrency, so anything that changes how the concurrency behaves has to reach inside all of them. And that's the second problem, the one I was never blaming. I spent years conflating the two, so here they are side by side:

- **Generics blocked the library.** Real blocker, out of my hands, fixed by Go 1.18.
- **The stages owning the concurrency blocked the TODO list.** My decision, taken on the first page, and type parameters wouldn't have touched it. A generic `stage[I, O] func(<-chan I) <-chan O` is the same trap with better types.

If I had written this post the day 1.18 shipped, I would have generified the sketch, published it, and still had four items outstanding.

### The question underneath

What I should have been asking in 2020, and wasn't: **who owns the concurrency?** In the sketch the answer is that each stage owns its own, permanently, and the caller fixes the topology by nesting. It's decided the moment you write the stage, and nobody can change it afterwards. Not even you, six years later, with the whole afternoon free.

That was the question worth waiting on, and I was waiting on the wrong one. On Thursday I'll take apart the library I finally wrote, [flow](https://github.com/pabloos/flow), which starts from the opposite premise: you implement the ends, and the library owns the middle. Generics are what let me write its types down. The premise is what made the TODO list evaporate.
