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
    flow.Slice(lines...),
    flow.Then(parse, flow.Then(enrich, score)),
    flow.Into(&out),
    flow.Workers(8),
)
```

Eight workers, each running the entire composed chain end to end, all pulling from one input channel. The stage count is about what you are computing; the worker count is about how much machine you want to spend on it. Compare that to Monday's question — *where would a second copy of the slow stage go?* — which now has a boring answer: nowhere, you just raise the number.

One detail in the diagram is easy to miss and it is not an accident: the consumer sits behind a single collector goroutine. `Into(&out)` appends to a slice with no mutex, and that is safe by construction rather than by luck.

### Under load, where the old example never went

None of this is worth much as an assertion. And the reason the 2020 post never caught its own problem is sitting in its last code listing: it ran `Exec(1, 2, 3, 4, 5)` over three arithmetic stages. Five integers, no failures, no skew, no reason to care about order — an example with nothing in it that could push back.

So here is one with teeth, and it is the kind of stage a backend actually has: most pipelines there are not computing, they are waiting — on a query, on another service, on a disk. The expensive stage below is an HTTP call to a local server that takes 10 ms to answer each request:

```go
fetch := flow.ProcessorFunc[string, profile](
    func(ctx context.Context, url string, emit func(profile) error) error {
        req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
        if err != nil {
            return err
        }
        resp, err := client.Do(req)
        if err != nil {
            return err
        }
        defer resp.Body.Close()

        var p profile
        if err := json.NewDecoder(resp.Body).Decode(&p); err != nil {
            return err
        }
        return emit(p)
    })
```

600 requests, so six seconds if you make them one at a time. Eight cores, median of five runs:

| | wall time | speedup | concurrent requests seen by the server |
|---|---:|---:|---:|
| `Workers(1)` | 6982 ms | — | 1 |
| `Workers(8)` | 846 ms | 8.3× | 8 |
| `Workers(32)` | 217 ms | 32.1× | 32 |
| `Workers(64)` | 113 ms | 61.8× | 64 |
| `Workers(128)` | 58 ms | 119.6× | 128 |
| `Workers(256)` | 37 ms | 187.8× | 256 |

Near-linear to 256 workers on eight cores, and the last column is the part I would frame: the concurrency the *server* observed tracked `Workers(n)` exactly, every time. The knob does precisely what it says.

What it does not do is tell you the right number, and that number has nothing to do with your hardware. The same pipeline doing CPU work instead — hashing in a loop — tops out at 3.5× on these eight cores, and workers past eight buy nothing, because parked goroutines are free and computing ones are not. For CPU work you could read the right setting off `nproc`. Here it is however many requests you are willing to have in flight, and that ceiling belongs to the service you are calling, not to you.

Which is the practical case for the concurrency being owned by the runtime. Nothing in those `Processor`s knows whether it is hashing or waiting on a socket, and nothing had to be rewritten to go from 3.5× to 188×.

(The caveat, since this is a synthetic backend: my test server has no connection limit and no saturation point, so it scales as far as I push it. A real one answers 256 concurrent requests by getting slower, or by rate-limiting you. The knob has a right value out there; it is just not one you can read off a spec sheet.)

### What it costs, and how it stops

**Ordering costs memory, not time — and only what leaves the pipeline.** To make order expensive, the first of 3,000 requests takes 1.5 seconds while the rest take 10 ms, and each response is a 4 KB profile. Sixty-four workers, heap sampled while it runs:

| | wall time | peak heap |
|---|---:|---:|
| `Workers(64)` | 1501 ms | 7.1 MB |
| `Workers(64)` + `Ordered()` | 1502 ms | 25.0 MB |

Same wall time, three and a half times the peak heap. The collector cannot deliver the second result until the first has arrived, so everything that finishes while the slow request is still out piles up in a map: here, nearly 3,000 profiles. Ordering is a buffer, and the buffer grows to fit the worst item in the batch.

The detail that took me a second run to see: my first attempt added a last stage that reduced each profile to a short `"user:score"` label, and the difference vanished — 7.4 MB against 7.6. The collector only ever holds *outputs*. What ordering costs is decided by what comes out of the pipeline, not by what went through it, which is a good reason to shrink results before the end rather than after.

**A failure stops the batch.** The server returns a 500 for request 1,500 of 3,000:

```
err = GET http://127.0.0.1:50417/profile?id=1500: 500 Internal Server Error
consumed = 1506 · requests aborted in flight = 12 · 276 ms
```

The error comes back from `Run` intact, roughly half the batch was never sent at all, and the twelve requests already on the wire were aborted rather than left to finish. That last part is not something `flow` does: it is the `ctx` passed into `NewRequestWithContext`, cancelled by the runtime the moment the first error landed.

**So does a deadline.** A 100 ms timeout on the same 3,000 requests stopped the run at 102 ms, with 512 consumed, 60 requests aborted in flight, and `context.DeadlineExceeded` back from `Run`.

That last result is only true as of this week. Until I ran this, `Run` returned `nil` on a cancelled context — a truncated run was indistinguishable from a finished one, and the toy example could never have shown it, because a toy example is never still running when somebody cancels.

### The list, finally

Every item on it turned into a consequence rather than a feature. Errors come back because each end returns one, and a `sync.Once` keeps the first and cancels the rest. Cancellation works because every send in the runtime sits in a `select` against `ctx.Done()` — where the 2020 version had no way to stop at all, and leaked the goroutines of anyone still blocked on a send. Buffering is `Prefetch(n)`, defaulting to zero, which is precisely the lock-step the old unbuffered channels gave you; the behaviour did not change, only the fact that it is now a named knob rather than a `make(chan int)` repeated in four places.

And ordering, which was never on the list, turned out to be the one with a real price tag and gets its own post next week.

Six years, and the change was one sentence. Not *how do I arrange the stages*, which is what the old post spent its length on and answered reasonably well. **Who owns the concurrency** — and once the answer stopped being "each stage, permanently, decided at the moment you write it", four things that had been rewrites became four arguments you pass.
