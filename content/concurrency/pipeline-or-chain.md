+++
title = "Is it a pipeline, or a chain?"
date = 2026-12-10
draft = true
+++

Go makes concurrent-looking code easy to write, which is not the same as making concurrent code easy to write. A handful of stages, a channel between each pair, a goroutine per stage: it has all the right vocabulary in it, and it may still be doing exactly one thing at a time.

Two questions tell you which one you have, and neither needs a profiler.

### Count the goroutines, then count the values in flight

Take the pipeline you have and count its goroutines. Then count how many values are moving through it at any single instant.

If the second number is bounded by the first — if every goroutine is holding exactly one item and waiting for somebody to take it — you have a chain, not a pipeline. Values enter at one end and walk the whole thing before the next one starts, and the throughput of the whole system is the throughput of its slowest link.

That is what unbuffered channels do when every stage is its own goroutine: they turn the chain into a lock-step conveyor. Which is a perfectly good design, as long as you know it is the one you have. The failure mode is believing you bought parallelism because you paid in goroutines.

### Ask what it would take to run three of the slowest stage

Point at the stage doing the heavy work and ask what has to happen for three copies of it to run at once.

If the answer is "raise a number", you are fine. If the honest answer is "write a merge function, decide what happens to output ordering, then thread it through the stages downstream", then the throughput of your system is a property of its structure rather than a knob you own.

Note that this is not about whether the work is *possible*. [The Go blog's pipelines article](https://go.dev/blog/pipelines) has been showing exactly how to do it, with working code, since 2014: a `merge` that fans in with a `sync.WaitGroup`, a `done` channel for cancellation, a bounded pool. It is possible.

It is just work you have to redo on every pipeline you write, and hand-woven work that has to be repeated is, in practice, work that does not get done. It becomes a TODO comment. I know, because I left four of them in [a post I wrote in 2020](/concurrency/pipelines-six-years-later/) and it took me six years to come back for them.

### What the two questions are really asking

Both of them circle the same thing: **who owns the concurrency in this design?**

When each stage owns its own — one goroutine, one channel, decided the moment the stage is written — then how much parallelism you get, whether you can cancel, how much sits in flight and what happens to ordering are all decided in the same breath, permanently, by whoever wrote the stages. Usually before anyone knew which stage would turn out to be slow.

It is a fine answer for a pipeline you will write once. It is a bad answer for a pipeline you intend to keep.
