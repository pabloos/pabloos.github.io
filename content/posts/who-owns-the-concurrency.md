+++
title = "Who owns the concurrency?"
description = "The pipeline library I finally wrote starts from one idea: you implement the ends, and the library owns the middle."
date = 2026-09-17

[extra]
image = "og/who-owns-the-concurrency.png"
+++

[On Monday](/posts/pipelines-six-years-later/) I took apart a pipeline I wrote in 2020 and found that its four unfinished TODO items (fan-out, cancellation, buffering, errors) were one problem wearing four hats: the stages owned the concurrency, so everything about the concurrency was their business.

This is the other answer, the one I arrived at in [flow](https://github.com/pabloos/flow). It starts from a single idea: **you implement the ends, and the library owns the middle.** Everything below follows from that.

### Three interfaces

If the library is going to own the middle, then what you write has to say nothing about the middle. That constraint produces these:

```go
type Producer[T any] interface {
    Produce(ctx context.Context, emit func(T) error) error
}

type Processor[I, O any] interface {
    Process(ctx context.Context, in I, emit func(O) error) error
}

type Consumer[T any] interface {
    Consume(ctx context.Context, v T) error
}
```

Monday's post was stuck on `type pipe <-chan int`, because in 2020 there was no way to write "a stage takes an `I` and gives back an `O`". `Processor[I, O]` is that sentence, and it's the part generics actually bought. Not performance or elegance, just the ability to write the type down at all.

The part that isn't about generics is `emit`. A stage doesn't return its output; it gets a function to call with it. Calling it once is a map, calling it zero times is a filter, calling it many times is a flatMap, so one shape covers all three and the runtime never has to ask which kind of stage it's holding. It also means a stage can't decide *where* its output goes. It can only say *here is a value*, and something else decides what that means.

Each interface has a function adapter beside it, the `http.HandlerFunc` trick: a named function type with the method defined on it, so you can pass a closure where an interface is expected.

```go
type ProcessorFunc[I, O any] func(ctx context.Context, in I, emit func(O) error) error

func (f ProcessorFunc[I, O]) Process(ctx context.Context, in I, emit func(O) error) error {
    return f(ctx, in, emit)
}
```

Use an interface when a stage has state of its own, and a closure when it doesn't. That's what stops "implement the ends" from turning into ceremony for the common case.

### No channels in the API

Read those three signatures again and notice what isn't there: a channel. Nothing commits to values travelling through one, to how many copies of a stage run, or to whether outputs arrive in order. That's the difference from 2020, where the channel *was* the type, and it's what leaves every one of those decisions open.

Composition stops needing a channel too. Two stages compose the way two functions compose:

```go
func Then[A, B, C any](p1 Processor[A, B], p2 Processor[B, C]) Processor[A, C] {
    return ProcessorFunc[A, C](func(ctx context.Context, in A, emit func(C) error) error {
        return p1.Process(ctx, in, func(mid B) error {
            return p2.Process(ctx, mid, emit)
        })
    })
}
```

The whole reversal is in those five lines: **the second stage becomes the `emit` that the first one is given.** When `p1` emits a value it isn't writing to a channel. It's calling `p2` directly, on the same goroutine, on the stack. A four-stage chain is four nested calls, and adding a fifth costs a function call rather than a goroutine and a channel handoff.

In 2020, adding a stage added a unit of concurrency whether you wanted one or not. Here the two have come apart, so the concurrency can't stay implicit. It has to be stated:

<svg viewBox="0 0 720 230" role="img" style="width:100%;height:auto;max-width:720px;display:block;margin:1.75rem auto" fill="none" stroke="currentColor" font-family="ui-monospace, SFMono-Regular, Menlo, monospace" font-size="12">
  <title>2026: one producer feeding a pool of workers, each running the whole composed chain, into a single collector</title>
  <text x="0" y="12" stroke="none" fill="currentColor" font-size="11" opacity="0.7">2026: stages compose, the pool runs them</text>
  <g stroke-width="1.2">
    <rect x="1" y="92" width="86" height="38" rx="2"/>
    <rect x="211" y="34" width="188" height="36" rx="2"/>
    <rect x="211" y="93" width="188" height="36" rx="2"/>
    <rect x="211" y="152" width="188" height="36" rx="2"/>
    <rect x="463" y="92" width="94" height="38" rx="2"/>
    <rect x="617" y="92" width="94" height="38" rx="2"/>
  </g>
  <g stroke="none" fill="currentColor" text-anchor="middle">
    <text x="44" y="116">Producer</text>
    <text x="305" y="57">p1 → p2 → p3</text>
    <text x="305" y="116">p1 → p2 → p3</text>
    <text x="305" y="175">p1 → p2 → p3</text>
    <text x="510" y="116">collector</text>
    <text x="664" y="116">Consumer</text>
  </g>
  <g stroke="none" fill="currentColor" font-size="10" opacity="0.75" text-anchor="middle">
    <text x="115" y="90">in chan</text>
    <text x="305" y="205">Workers(3)</text>
    <text x="510" y="145">1 goroutine</text>
  </g>
  <g stroke-width="1.2">
    <path d="M87 111 H149"/>
    <path d="M149 111 V52 H205"/><path d="M199 48 l6 4 -6 4"/>
    <path d="M149 111 H205"/><path d="M199 107 l6 4 -6 4"/>
    <path d="M149 111 V170 H205"/><path d="M199 166 l6 4 -6 4"/>
    <path d="M399 52 H431 V111 H457"/><path d="M451 107 l6 4 -6 4"/>
    <path d="M399 111 H457"/><path d="M451 107 l6 4 -6 4"/>
    <path d="M399 170 H431 V111 H457"/><path d="M451 107 l6 4 -6 4"/>
    <path d="M557 111 H611"/><path d="M605 107 l6 4 -6 4"/>
  </g>
  <g fill="currentColor" stroke="none">
    <circle cx="118" cy="111" r="3"/>
  </g>
  <text x="0" y="222" stroke="none" fill="currentColor" font-size="11" opacity="0.7">stages are function calls inside a worker · parallelism is an argument · one goroutine touches the Consumer</text>
</svg>

```go
err := flow.Run(ctx,
    flow.Slice(lines...),
    flow.Then(parse, flow.Then(enrich, score)),
    flow.Into(&out),
    flow.Workers(8),
)
```

The stage count is about what you're computing; the worker count is about how much machine you want to spend on it. Six hundred HTTP calls of 10 ms each take 6982 ms one at a time and 37 ms with `Workers(256)` on eight cores, and the server saw exactly as many concurrent requests as there were workers, every time. The right number isn't something you can read off `nproc`, either: the same pipeline doing CPU work tops out at 3.5× on those same cores, because parked goroutines are free and computing ones aren't.

One detail in the diagram is easy to miss, and it's deliberate: the consumer sits behind a single collector goroutine. `Into(&out)` appends to a slice with no mutex, and that's safe by construction rather than by luck.

### Ordering and cancellation

These two are worth pulling out, because they are what those open signatures buy. Neither is a feature bolted on top; both are decisions the runtime gets to make precisely because no stage ever claimed them.

Ordering is opt-in. Every input gets a sequence number on its way in, and with `Ordered()` the collector holds finished results back until the missing one arrives, so the consumer sees input order even though the pool didn't produce it:

<svg viewBox="0 0 720 240" role="img" style="width:100%;height:auto;max-width:720px;display:block;margin:1.75rem auto" fill="none" stroke="currentColor" font-family="ui-monospace, SFMono-Regular, Menlo, monospace" font-size="12">
  <title>While the first request is still running, ordered delivery holds every finished result in a map</title>
  <text x="0" y="12" stroke="none" fill="currentColor" font-size="11" opacity="0.7">while request #1 is still out (1.5 s), these four have already finished</text>
  <g stroke-width="1.2">
    <rect x="1" y="92" width="118" height="40" rx="2"/>
  </g>
  <g stroke="none" fill="currentColor" text-anchor="middle">
    <text x="60" y="110">#1</text>
    <text x="60" y="126" font-size="10" opacity="0.75">still running</text>
  </g>
  <text x="150" y="36" stroke="none" fill="currentColor" font-size="11" opacity="0.75">without Ordered()</text>
  <g stroke-width="1.2">
    <rect x="150" y="44" width="50" height="28" rx="2"/>
    <rect x="210" y="44" width="50" height="28" rx="2"/>
    <rect x="270" y="44" width="50" height="28" rx="2"/>
    <rect x="330" y="44" width="50" height="28" rx="2"/>
    <path d="M388 58 H548"/><path d="M542 54 l6 4 -6 4"/>
    <rect x="556" y="44" width="120" height="28" rx="2"/>
  </g>
  <g stroke="none" fill="currentColor" text-anchor="middle">
    <text x="175" y="63">#2</text><text x="235" y="63">#3</text><text x="295" y="63">#4</text><text x="355" y="63">#5</text>
    <text x="616" y="63">Consumer</text>
  </g>
  <text x="150" y="88" stroke="none" fill="currentColor" font-size="10" opacity="0.75">delivered as they finish · peak heap 7.1 MB</text>
  <text x="150" y="138" stroke="none" fill="currentColor" font-size="11" opacity="0.75">with Ordered()</text>
  <g stroke-width="1.2">
    <rect x="142" y="146" width="246" height="44" rx="2" stroke-dasharray="4 3"/>
    <rect x="150" y="152" width="50" height="28" rx="2"/>
    <rect x="210" y="152" width="50" height="28" rx="2"/>
    <rect x="270" y="152" width="50" height="28" rx="2"/>
    <rect x="330" y="152" width="50" height="28" rx="2"/>
    <path d="M396 166 H462"/><path d="M456 162 l6 4 -6 4"/>
    <path d="M472 148 V184"/>
    <rect x="556" y="152" width="120" height="28" rx="2" opacity="0.45"/>
  </g>
  <g stroke="none" fill="currentColor" text-anchor="middle">
    <text x="175" y="171">#2</text><text x="235" y="171">#3</text><text x="295" y="171">#4</text><text x="355" y="171">#5</text>
    <text x="616" y="171" opacity="0.45">Consumer</text>
  </g>
  <text x="484" y="171" stroke="none" fill="currentColor" font-size="10" opacity="0.75">waits for #1</text>
  <text x="150" y="206" stroke="none" fill="currentColor" font-size="10" opacity="0.75">held in a map until #1 arrives · peak heap 25.0 MB</text>
  <text x="0" y="232" stroke="none" fill="currentColor" font-size="11" opacity="0.7">the map holds outputs, not inputs: ordering costs whatever your results weigh</text>
</svg>

That's why it's opt-in: it costs memory rather than time. In a run where the first of 3,000 requests took 1.5 seconds and each result was a 4 KB profile, `Ordered()` left the wall time untouched and took the peak heap from 7.1 MB to 25 MB. It only charges for what leaves the pipeline, which is a good reason to shrink results before the end rather than after.

Cancellation falls out of the same place. Every send inside the runtime sits in a `select` against `ctx.Done()`, and the first end to fail wins: a `sync.Once` keeps its error and cancels everything else. A 500 on request 1,500 of 3,000 came back from `Run` intact, with half the batch never sent; a 100 ms deadline stopped the run at 102 ms. In both cases the requests already on the wire were aborted rather than left to finish, and that part isn't `flow` at all: it's the same `ctx`, handed to `NewRequestWithContext` by a stage that knows nothing about any of this.

The 2020 design could do neither. There was no `ctx` to thread and no single place to hold a result back, because both would have meant editing every stage by hand, and then editing them again the next time.

### What changed

Six years, and what changed was a single question. Not *how do I arrange the stages*, which is what the old post spent its length on and answered reasonably well, but **who owns the concurrency?**

Once the answer stopped being "each stage, permanently, decided the moment you write it", the four items on that TODO list stopped being rewrites and became arguments you pass.

The library is at [github.com/pabloos/flow](https://github.com/pabloos/flow), a handful of files with no dependencies beyond the standard library. If you put it to work on a pipeline of your own, I'd like to hear where it gets in the way.
