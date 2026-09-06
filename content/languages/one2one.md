+++
title = "1:1"
date = 2021-01-16T21:42:37+01:00
aliases = ["/languages/1to1/"]
+++

### The basic idea: a way to get rid of classes

There are many well identified classes that only have a one public method, such as iterators, lexers and that kind of walk-on-collections objects. I call this case a 1:1 class: when a class has just one public method.

```js
class Greet {
    constructor(greet) {
        this.greet = greet;
    }

    greet(name) {
        console.log(this.greet + " " +  name);
    }
}

const salut = new Greet("Hello");

salut.greet("Pablo"); // Hello Pablo
```

For some cases I use the following instead. That's it, just a functor:

```js
const GreetBuilder = greet => name => console.log(greet + " " +  name);

const greet = GreetBuilder("Bonjour");

greet("Pablo"); // Hello Pablo
```

As you can see the new way to define classes is way more concise.

### Private methods

Also there are more examples that increases the code complexity by including internal methods. So you can define private methods keeping them as functions defined inside our functor:

```js
// the classic approach:
class Greet {
    constructor(greet) {
        this.greet = greet;
        this.intensity = 0;
    }

    greet(name) {
        console.log(this.greet + " " + name + ("!" * this.intensity));

        addIntensity();
    }

    addIntensity() {
        this.intensity++;
    }
}

// with the new one becomes:
const GreetBuilder = greet => {
    let intensity = 0;

    const addIntensity = () => intensity++; // this method is private 

    return name => { // this works as a public method
        console.log(greet + " " + name + "!".repeat(intensity));

        addIntensity();
    }
}
```

### ... but what about 1:n cases?

Well... that depends on the language, but a couple of solutions would be:

- return an array of functions (demultiplexer): not very idiomatic, as you have to explicty document which one is method1 or method2, instead of using symbol names
- for methods that acts as commands (they don't return anything), you could use a multiplexer caller inside the function returned. Even less idiomatic, since you need to pass an identifier in order to select each method:

```js
const mult = () => {
    const noParams = () => {};
    const wParams = (param1, param2) => {};

    return cmd => {
        switch(cmd) {
            case "noParams": 
                noParams();
                break;
            case "wParams":
                return wParams; // we return the whole function instead of call it to give the caller the chance to pass the params
        }
    }
}
```
