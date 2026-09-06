+++
title = "Use Go interfaces"
date = 2020-06-28T12:43:10+02:00
slug = "usegointerfaces"
+++

tl;dr:

|    from\to   |       io.Writer       |         io.Reader         |            string           |      []byte     |   bytes.Buffer  |
|:------------:|:---------------------:|:-------------------------:|:---------------------------:|:---------------:|:---------------:|
|   io.Writer  |           --          |          io.Pipe          |        io.WriteString       |        N/A        |        N/A        |
|   io.Reader  |        io.Copy        |             --            |       strings.Builder       |        N/A        |        N/A        |
|    string    | bytes.NewBufferString |     strings.NewReader     |              --             | []byte("io") |                 |
|    []byte    |    bytes.NewBuffer    | bytes.New{Reader/Buffer} | string(byteSlice) |        --       | bytes.NewBuffer |
| bytes.Buffer |          it's         |            it's           |          buf.String         |    buf.bytes    |        --       |

Go has become a very popular language, so there's day to day multiple posts and tutorials.
But so many of them are missusing the basic interfaces, and they are a core design concept.
Let's check it:

### io.Writer and io.Reader

io.Writer should be most used interface as we're working with a language that has distributed systems programming in mind.

```go
func(w http.ResponseWriter, req http.Request) {
    w.Write([]byte("Hello from the web server!"))
    // Don't do that. Do this instead:

    io.WriteString(w, "Hello from the web server!")
    // don't forget to check len and err returned
}
```

* This goes into the polemic ones:

```go
// Nop (unless you place that on the main).
fmt.Print("hello tty!")
fmt.Println(err)

// Please:
io.WriteString(os.Stdout, "hello tty!")
fmt.Fprintln(os.Stderr, err.Error())

// Which allows you to use your terminal session output as a parameter (and that's a more pleausre way to test).
f, err := os.Create("myFile")

io.WriteString(f, "hello tty!")
```

* This maybe it's less obvious, but in the same mood:

```go
conn, err := net.Listen("tcp", ":8080")

// Everyone out there is doing this...
conn.Write([]byte("Hello from the tcp net!"))

// better ->
io.WriteString(conn, "Hello from the tcp net!")
```

Oh, and here's a good one: you can use whatever of the previous objects as a log output.

```go
var logger log.Logger

logger.setOutput(w) // a file, a net connection, or a http.ResponseWriter... or the default os.Stdout
```

The io.Reader could help us decoupling the user input in a scanner (it could be a file, the os.Stdin, or a stream):

```go
scanner, err := bufio.NewScanner(os.Stdin)
scanner, err := bufio.NewScanner(configFile)
// ...
```

### io.Copy and io.CopyBuffer

io.Copy writes the contents of a Reader to a Writer, so you could use something like:

```go
io.Copy(os.Stdout, request.Body) // prints the request body
io.Copy(response, request.Body) // send back the request
io.Copy(myFile, request.Body) // send a file content or
io.Copy(response, myFile) // send back the file content
```

io.CopyBuffer does the same, but we use our own buffer instead of let the copy function allocate another one. Because of this we could reuse it:

```go
r1 := strings.NewReader("You said goodbye...\n")
r2 := strings.NewReader("... and I said Hello\n")
buf := make([]byte, 12)

io.CopyBuffer(os.Stdout, r1, buf);
io.CopyBuffer(os.Stdout, r2, buf);
// don't forget to ckeck the err and n bytes copied returned!
```

### io.Pipe

This is, in some way, the reverse function of io.Copy: puts everything in the pipe writer avaliable to read from the pipe reader:

```go
pr, pw := io.Pipe()

go func() { // we need to write in a goroutine, because Pipe uses a blocking channel inside
    defer pw.Close()

    io.WriteString(pw, "Hello")
}()

io.Copy(os.Stdout, pr)
```

### io.Closer (a special case)

When working with some readers/writers you should close the resource at the end in order to avoid leaks.

```go
func(rc io.ReaderCloser) { // ask for a reader that use a close method: net.Conn, request.Body, a file...
    defer rc.Close()
}
```

### MultiReader and MultiWriter

* MultiReader concatenate various readers into one
* MultiWriter returns a writer which will perform a write on every writer you passed

```go
newReader := io.MultiReader(file, request)
io.Copy(newReader, os.Stdout)

sink := io.MultiWriter(file, os.Stdout)
io.WriteString(sink, "A string written for a file and a tty")
```

### Fork: TeeReader

As you can see in the previous example with the multiwriter, we are setting a fork, so if you write on the result is the same as if you write directly on both writers you passed. The io library has a function that does this the same as the tee UNIX command do:

```go
// read from request, create a tee reader and also puts the request on stdout
tee := io.TeeReader(request.Body, os.Stdout)
io.Copy(tee, file)
```
