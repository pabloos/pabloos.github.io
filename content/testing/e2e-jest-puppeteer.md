+++
title = "E2E with Jest And Puppeteer. How I do it."
date = 2020-04-09T12:03:21+02:00
path = "testing/e2e-with-jest-and-puppeteer.-how-i-do-it/"
+++

As a backend developer E2E testing is a must for me. E2E testing does not only check the features of the frontend, it cares about the whole system. A good match for this purpose on Node it's the jest and puppeteer tandem for testing web apps.

(Note: From now on I assume that you have some experience with the API of both technologies)

### About the dependencies

You will find a bunch of posts about this topic on the internet. Some will tell you to install _jest-puppeteer_, but I don't like the way it works and what it offers to you. _jest-puppeteer_ it's a preset that will "insert" on your code a browser and a page objects already defined to use on your tests. That means two things: global symbols and a break in your storytelling: where the browser instance comes from? For this reason I prefer to define manually my browser and page instances.

```javascript
define('E2E test suite', () => {
  let browser, page

  beforeAll(() => {
    browser = await puppeteer.launch(config)
    page = await browser.newPage()
  })
})
```

If you write this you're telling the story from the beginning: first, setup the environement. But there's another element that until now we're not showing: the server app. And there's when some people would tell you to use the launher built-in on the _jest-puppeteer_ preset. It's usefull, as it run the server via a npm command for you... but you can do it by yourself (me neither want to exec a shell command from code, that feels tricky for me):

```javascript
const app = require('./myApp')

define('E2E test suite', () => {
  let server, browser, page

  beforeAll(() => {
    server = await app.run()
    browser = await puppeteer.launch(config)
    page = await browser.newPage()
  })

  // ... tests

  afterAll(() => {
    await page.close()
    await browser.close()
    await server.shutdown()
  })
})
```

Because of this, now you have a basic landscape with all the actors... with no unnecesary dependencies.

#### ... hit me baby one more time

A tip for myself that I use on almost every scenario is to reload the page before each test, in case that I need to start every test from the zero state.

```javascript
beforeEach(() => {
  await page.reload()
})
```

Now... the tests.

### A simple test with interactions

You will find a puppeteer test on every post that seems like a sequential way of interactions with the elements. So let's see an funny example to play with... a silly statement of income:

```javascript
test('check the interaction', () => {
  const revenueInput = await page.$('input#revenue.form-input')

  await revenueInput.type('1000,00')

  const expensesInput = await page.$('input#expenses.form-input')

  await expensesInput.type('2000,00')

  const profitInput = await page.$('input#profit.form-input')

  await profitInput.type('1000,00')

  const submitButton = await page.$('button#queryButton')

  await submitButton.click()
  
  const resultBox = await page.$('div#resultBox')
  
  const result = resultBox.value
  const expected = "Ok. You should pay $100"
  
  expect(result).toBe(expected)
})
```

Yes. Great. But it can be better. It can be asyncronous. Until the process logic allows it, you know...

```javascript
test('check the interaction', async () => {
  const inputQuerys = ['input#revenue.form-input', 'input#expenses.form-input','input#profit.form-input']
  const inputData = ['1000,00', '2000,00', '1000,00']

  const promises = inputQuerys.map((query, index) => page.$(query).then(input => input.type(inputData[index])))

  const submitButton = await page.$('queryButton')

  Promise.all(promises).then((await submitButton.click()))

  const resultBox = await page.$('div#resultBox')

  const result = resultBox.value
  const expected = "Ok. You should pay $100"
  
  expect(result).toBe(expected)
})
```

This way we give the runtime the chance of make the typing work concurrently and maybe run this kind of heavy tests faster. E2E testing on browser usually gets sooo slow, and on each test you will need to set a big timeout number.

### Table-Driven tests refactor

Yeah, but it could be even better, Table-Driven Tests to the rescue!

```javascript
  test.each`
  revenue    | expenses   | profit     | expected
  ${`1,000`} | ${'2,000'} | ${`1,000`} | ${`You must pay $100`}
  ${`3,000`} | ${'2,000'} | ${`5,000`} | ${`You must pay $600`}
  ${`1,00`}  | ${'2,00'}  | ${`300`}   | ${`You mustn't pay anything`}
  `
  
  ('E2E taxes: $revenue, $expenses, $profit => $expected', testCase => {
    const inputQuerys = ['input#name', 'input#address','input#phone']
    const inputData = Object.values(testCase)

    const inputs = inputQuerys.map((inputQuery, index) => page.$(inputQuery).then(input => input.type(inputData[index])))

    const submitButton = await page.$('queryButton')

    Promise.all(inputs).then((await submitButton.click()))

    const resultBox = await page.$('div#resultBox')

    const result = resultBox.value

    expect(result).toBe(testCase.expected)
  })
```

This way you can define all of your tests cases on the table and use the same function on each of them. It's more legible, you decouple data and functionality, and it allows you to add more tests cases with ease.
