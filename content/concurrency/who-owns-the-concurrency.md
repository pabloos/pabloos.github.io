+++
title = "Who owns the concurrency?"
date = 2026-09-17
draft = true
+++

[On Monday](/concurrency/pipelines-six-years-later/) I took apart a pipeline I wrote in 2020 and found that its four unfinished TODO items — fan-out, cancellation, buffering, errors — were one problem wearing four hats. Most of them already had answers in [the Go blog article](https://go.dev/blog/pipelines) I had copied the shape from, and I had used none of them, because in that design each answer is hand-woven into every stage and re-woven whenever the pipeline changes. The stages owned the concurrency, so everything about the concurrency was their business.

This is the other answer, the one I arrived at in [flow](https://github.com/pabloos/flow). It starts from a single sentence: **you implement the ends, and the library owns the middle.** Everything below is what that sentence forces.

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

Monday's post was stuck on `type pipe <-chan int`, because in 2020 there was no way to write "a stage takes an `I` and gives back an `O`". `Processor[I, O]` is that sentence, and it is the part generics actually bought: not performance, not elegance, just the ability to write the type down at all. Everything else here was available in 2020 and I did not see it.

Three decisions are packed into those three types, and they are worth pulling apart before any of the code makes sense.

**A stage does not return its output; it is handed a function to call with it.** That `emit` is the whole trick. Calling it once is a map, calling it zero times is a filter, calling it many times is a flatMap — one shape covers all three, and the runtime never has to ask which kind of stage it is holding. It also means a stage cannot decide *where* its output goes. It can only say *here is a value*, and something else decides what that means.

**No channel appears in any of those signatures**, which is exactly what the 2020 design could not manage. Nothing there commits to values travelling through a channel, to how many copies of a stage run, or to whether outputs arrive in order. All of it is left open, which is what makes it possible to change those decisions later without touching a single stage.

**They are interfaces with function adapters beside them**, the `http.HandlerFunc` trick: a named function type with the method defined on it, so you can pass a closure where an interface is expected.

```go
type ProcessorFunc[I, O any] func(ctx context.Context, in I, emit func(O) error) error

func (f ProcessorFunc[I, O]) Process(ctx context.Context, in I, emit func(O) error) error {
    return f(ctx, in, emit)
}
```

Interfaces when a stage has state worth naming, closures when it does not. It is what stops "implement the ends" from turning into ceremony for the common case.

Three types, and none of them says anything about how the work runs. That is not minimalism for its own sake — it is the price of the opening sentence. Anything else in those signatures would be the stage making a decision that belongs to the runtime.

### Composition stops needing a channel

Once a stage is a function that emits, composing two of them is composing two functions, and it needs no machinery at all:

```go
func Then[A, B, C any](p1 Processor[A, B], p2 Processor[B, C]) Processor[A, C] {
    return ProcessorFunc[A, C](func(ctx context.Context, in A, emit func(C) error) error {
        return p1.Process(ctx, in, func(mid B) error {
            return p2.Process(ctx, mid, emit)
        })
    })
}
```

Read it slowly, because the whole reversal is in those five lines: **the second stage becomes the `emit` that the first one is given.** When `p1` emits a value it is not writing to a channel — it is calling `p2` directly, on the same goroutine, on the stack. A four-stage chain is four nested calls. Adding a fifth costs a function call rather than a goroutine and a channel handoff.

In 2020, adding a stage added a unit of concurrency whether you wanted one or not. Here the two have come apart completely, which leaves the concurrency with nowhere to hide. It now has to be stated out loud:

<svg viewBox="0 0 720 230" role="img" style="width:100%;height:auto;max-width:720px;display:block;margin:1.75rem auto" fill="none" stroke="currentColor" font-family="ui-monospace, SFMono-Regular, Menlo, monospace" font-size="12">
  <title>2026: one producer feeding a pool of workers, each running the whole composed chain, into a single collector</title>
  <text x="0" y="12" stroke="none" fill="currentColor" font-size="11" opacity="0.7">2026 — stages compose, the pool runs them</text>
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
    flow.Slice(1, 2, 3, 4),
    flow.Then(parse, flow.Then(enrich, score)),
    flow.Into(&out),
    flow.Workers(8),
)
```

Eight workers, each running the entire composed chain end to end, all pulling from one input channel. The stage count is about what you are computing; the worker count is about how much machine you want to spend on it. Compare that to Monday's question — *where would a second copy of the slow stage go?* — which now has a boring answer: nowhere, you just raise the number.

One detail in the diagram is easy to miss and it is not an accident: the consumer sits behind a single collector goroutine. `Into(&out)` appends to a slice with no mutex, and that is safe by construction rather than by luck. Handing the user a rule to follow ("your consumer must be thread-safe") would have been the lazy version.

### The list, finally

Four items, all of them consequences rather than features:

**Errors.** Every end returns an `error`, so the first one to fail wins: a `sync.Once` stores it and cancels everything else. Fail-fast is not something I added — it is what you get once there is somewhere to return an error from.

**Cancellation.** Every send in the runtime sits in a `select` against `ctx.Done()`. The 2020 version had no way to stop: if the consumer walked away, the producer blocked on a send forever and every goroutine behind it leaked.

**Buffers.** `Prefetch(n)` sets how many items may queue ahead of the pool. The default is zero — strict lock-step, exactly what the old unbuffered channels did. The behaviour did not change; what changed is that it stopped being `make(chan int)` repeated in four places and became one knob with a name.

**Ordering**, which was not on the list, and cost the most of the four. In 2020 it was free, because there was only ever one value in a stage: output order was input order by construction. Put eight workers on one channel and outputs finish whenever they finish. Getting the original order back costs real memory, and it is opt-in — `Ordered()` — because plenty of pipelines do not care and the ones that do should know what they are paying. That one needs its own post, and it gets one next week.

Six years, and the change was one sentence. Not *how do I arrange the stages*, which is what the old post spent its length on and answered reasonably well. **Who owns the concurrency** — and once the answer stopped being "each stage, permanently, decided at the moment you write it", four things that had been rewrites became four arguments you pass.
