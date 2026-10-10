# Learning Lua: A Gentle Introduction

Welcome! If you've never written a line of Lua before, you're in the right
place. This guide is designed to be read slowly, with a cup of tea, and to
make you actually *understand* what's happening — not just memorize syntax.

We'll take our time. Every concept will be introduced with an analogy or
intuition first, then the syntax, then a chance to check that it clicked.
By the end, you'll be writing Ember game behaviors with confidence.

---

## Table of Contents

1. [What Is Lua, and Why Does Ember Use It?](#1-what-is-lua-and-why-does-ember-use-it)
2. [Basic Syntax: Variables, Types, and Control Flow](#2-basic-syntax-variables-types-and-control-flow)
3. [Tables: The One Data Structure](#3-tables-the-one-data-structure)
4. [Functions and Closures](#4-functions-and-closures)
5. [Metatables and Object-Oriented Programming](#5-metatables-and-object-oriented-programming)
6. [Coroutines: Pausing and Resuming Work](#6-coroutines-pausing-and-resuming-work)
7. [Where to Go Next](#7-where-to-go-next)

---

## 1. What Is Lua, and Why Does Ember Use It?

### The Big Picture

Lua (pronounced "LOO-ah", Portuguese for "moon") is a small, fast scripting
language that lives *inside* other programs. It was created in 1993 by
researchers in Brazil who wanted a language that could be embedded into
larger applications to make them customizable. Think of it as the "brain"
that you can drop into a game engine, a web server, or an embedded device.

Lua is not the program you run. It's the language you use to *tell* the
program what to do.

### Why Ember Uses Lua

Ember is a game engine written in Rust — a fast, safe, compiled language.
But Rust is not something you want to recompile every time you tweak a
game mechanic. So Ember embeds a Lua virtual machine (specifically
**LuaJIT**, a just-in-time compiler for Lua 5.1) and lets you write game
logic in Lua.

This gives you the best of both worlds:

- **Rust** handles the heavy lifting: rendering, physics, memory safety.
- **Lua** handles the creative part: what happens when you press a button,
  how an enemy behaves, what a cutscene does.

Lua is perfect for this role because it's:

- **Small.** The entire language fits in your head. There are no obscure
  features to trip over.
- **Fast.** LuaJIT is one of the fastest dynamic language runtimes in
  existence.
- **Embeddable.** It was designed from day one to live inside another
  program.
- **Simple to sandbox.** Ember can restrict what Lua code can do, so a
  broken script won't crash the whole game.

### A Quick Note on LuaJIT

You'll see "LuaJIT" mentioned in Ember's docs. LuaJIT is a special
implementation of Lua 5.1 that compiles Lua code to native machine code
at runtime. For you, the programmer, this means:

- Your Lua code runs *fast* — often within a few percent of native C.
- You're working with Lua 5.1 semantics, not the newer 5.3/5.4.
- A few newer Lua features (like integer division `//`) are **not**
  available. We'll point these out when they matter.

---

## 2. Basic Syntax: Variables, Types, and Control Flow

### 2.1 Variables: Labeled Boxes

Imagine you're moving into a new apartment. You have a bunch of boxes, and
you label them: "books", "kitchen stuff", "winter clothes". A **variable**
is exactly that — a labeled box where you store a value.

In Lua, you create a variable with the `local` keyword:

```lua
local name = "hero"      -- a box labeled "name" containing the text "hero"
local health = 100       -- a box labeled "health" containing the number 100
local is_alive = true    -- a box labeled "is_alive" containing true
```

The `=` sign means "put this value into the box". You can look inside the
box anytime by using its name:

```lua
print(name)    -- hero
print(health)  -- 100
```

You can also replace what's in the box:

```lua
health = 75    -- the box now contains 75 instead of 100
```

> **Why `local` matters:** Without `local`, you create a *global* variable
> — a box that anyone in the apartment building can open. In a game with
> hundreds of scripts, that's a recipe for chaos. Always use `local`
> unless you have a very good reason not to.

#### Common Mistakes

```lua
-- Mistake 1: Forgetting `local` (creates a global!)
health = 100        -- oops, this is global

-- Mistake 2: Using a variable before it creates it
print(score)        -- nil (the box doesn't exist yet)
score = 10

-- Mistake 3: Typos in variable names
local my_health = 100
print(my_heath)      -- nil! Lua doesn't warn you about typos
```

> **Why This Matters for Games:** In game code, you'll have variables for
> things like `player_position`, `enemy_count`, `is_jumping`. Using `local`
> keeps each script's variables separate, so one script can't accidentally
> overwrite another's data.

> **Check Your Understanding:** What does the following code print?
> ```lua
> local x = 10
> local y = x
> x = 20
> print(y)
> ```
> <details><summary>Answer</summary>
> `10`. Assigning `y = x` copies the *value* of `x` into `y`. Changing `x`
> later doesn't affect `y`. They're separate boxes.
> </details>

---

### 2.2 Types: What Kind of Thing Is in the Box?

Lua has a small number of **types** — categories that describe what kind of
value a variable holds. Think of it like different kinds of containers:
a liquid container, a solid container, a yes/no switch.

Here are the types you'll use every day:

```lua
local n = 42              -- number (a double-precision floating-point number)
local s = "hello"         -- string (text)
local b = true            -- boolean (true or false)
local t = {1, 2, 3}       -- table (a collection — we'll cover this soon!)
local f = function() end  -- function (a reusable chunk of code)
local nothing = nil       -- nil (the absence of a value — an empty box)
```

There are also `userdata` (data from the engine, like an entity handle) and
`thread` (a coroutine — we'll meet these later).

#### Numbers: Everything Is a Float

In many languages, you have separate types for integers (`int`) and
floating-point numbers (`float`). Lua (5.1 / LuaJIT) has only **one** number
type: a 64-bit double-precision float. This means:

```lua
local a = 10 / 3     -- 3.3333333333333335 (float division)
local b = 10 % 3     -- 1 (modulo — the remainder)
local c = 2^10       -- 1024 (exponentiation — 2 to the power of 10)
```

Notice that `10 / 3` gives `3.333...`, not `3`. In Lua 5.3+, there's an
integer division operator `//`, but **LuaJIT doesn't have it**. If you need
integer division, use `math.floor(10 / 3)`.

> **Why This Matters for Games:** Game math (positions, velocities, health)
> is almost all floating-point. The engine passes `f32` values to and from
> Lua, and LuaJIT's doubles are more than precise enough. You rarely need
> to worry about integer vs. float in practice.

#### Strings: Immutable Text

Strings are sequences of characters. You can create them with double or
single quotes:

```lua
local s = "hello"
local t = 'world'                    -- same thing
local u = s .. " " .. t              -- concatenation: "hello world"
local n = #s                         -- length: 5
```

The `..` operator glues strings together. The `#` operator gives you the
length.

Strings are **immutable** — you can't change a character inside a string.
When you concatenate, Lua creates a brand-new string. This is usually fine,
but in a tight loop that builds a string character by character, it can be
slow. In those cases, build a table of parts and use `table.concat`:

```lua
-- Slow (creates a new string every iteration):
local result = ""
for i = 1, 1000 do
  result = result .. "x"
end

-- Fast (one string created at the end):
local parts = {}
for i = 1, 1000 do
  parts[i] = "x"
end
local result = table.concat(parts)
```

#### Booleans and nil: The Truth About Truthiness

Lua has two boolean values: `true` and `false`. But Lua also has a concept
of "truthy" and "falsy" that trips up beginners:

```lua
if 0 then print("0 is truthy!") end           -- prints! (0 is truthy)
if "" then print("empty string is truthy!") end -- prints! ("" is truthy)
if nil then print("never") end                -- never prints
if false then print("never") end              -- never prints
```

**Only `false` and `nil` are falsy.** Everything else — including `0` and
`""` — is truthy. This is different from languages like Python or JavaScript,
where `0` and `""` are falsy.

`nil` is Lua's way of saying "there is no value here". It's like an empty
box. If you try to use a variable that doesn't exist, you get `nil`.

#### Common Mistakes

```lua
-- Mistake 1: Expecting 0 to be falsy
local count = 0
if count then
  -- This DOES run! 0 is truthy in Lua.
end

-- Mistake 2: Comparing strings with == instead of ..
local a = "hello"
local b = "hello"
print(a == b)     -- true (== compares values for strings)

-- Mistake 3: Forgetting that nil is falsy but 0 is not
local maybe_nil = nil
if maybe_nil then
  -- This does NOT run (nil is falsy)
end
local zero = 0
if zero then
  -- This DOES run (0 is truthy)
end
```

> **Why This Matters for Games:** You'll write conditions like
> `if player.hp <= 0 then ... end` or `if input.is_pressed("jump") then ... end`.
> Understanding truthiness prevents bugs where a health of `0` accidentally
> triggers a "player is alive" branch.

> **Check Your Understanding:** What does this print?
> ```lua
> local hp = 0
> if hp then
>   print("alive")
> else
>   print("dead")
> end
> ```
> <details><summary>Answer</summary>
> "alive"! Because `0` is truthy in Lua. If you want to check for zero, you
> need an explicit comparison: `if hp > 0 then`.
> </details>

---

### 2.3 Control Flow: Making Decisions and Repeating Actions

Control flow is how you tell Lua "do this *if* that's true" or "do this
*ten times*".

#### If / Elseif / Else

```lua
local x = 5

if x > 0 then
  print("positive")
elseif x < 0 then
  print("negative")
else
  print("zero")
end
```

The keywords are `if`, `then`, `elseif`, `else`, and `end`. Every `if`
needs a matching `end`. You can have as many `elseif` branches as you want.

#### While Loops

A `while` loop repeats as long as a condition is true:

```lua
local i = 0
while i < 10 do
  i = i + 1
end
-- i is now 10
```

Be careful: if the condition never becomes false, you get an **infinite
loop** and your game freezes. Always make sure something inside the loop
moves the condition toward false.

#### Numeric For Loops

When you know exactly how many times you want to repeat, use a numeric
`for`:

```lua
for i = 1, 10 do          -- 1, 2, 3, ..., 10 (inclusive on both ends)
  print(i)
end

for i = 10, 1, -2 do      -- 10, 8, 6, 4, 2 (counting down by 2)
  print(i)
end
```

The three parts are: **start**, **stop**, and **step** (optional, defaults
to 1). The loop variable `i` is local to the loop — you can't access it
after the loop ends.

#### Generic For Loops (Iterating Tables)

We'll cover tables in detail in the next section, but here's a preview:
you can loop over a table's contents with `pairs` or `ipairs`:

```lua
local colors = {"red", "green", "blue"}

for i, color in ipairs(colors) do
  print(i, color)    -- 1 red, 2 green, 3 blue
end
```

`ipairs` goes through the array part in order. `pairs` goes through all
keys (we'll see the difference soon).

#### Common Mistakes

```lua
-- Mistake 1: Infinite loop (condition never becomes false)
local i = 0
while i < 10 do
  print(i)
  -- oops, forgot i = i + 1
end

-- Mistake 2: Off-by-one in for loops
for i = 1, 10 do
  -- This runs 10 times (i = 1 through 10), not 9 times.
  -- Lua's for is inclusive on both ends.
end

-- Mistake 3: Modifying the loop variable (doesn't affect the loop)
for i = 1, 10 do
  i = 100    -- This does NOT skip to the end. Lua ignores this.
  print(i)   -- Still prints 1, 2, 3, ...
end
```

> **Why This Matters for Games:** Control flow is the skeleton of game logic.
> `if input.is_pressed("jump") then` is an if statement. `for i = 1, #enemies do`
> is a for loop. `while player.is_alive do` is a while loop. You'll use
> these constantly.

> **Check Your Understanding:** How many times does this loop run?
> ```lua
> for i = 1, 10, 3 do
>   print(i)
> end
> ```
> <details><summary>Answer</summary>
> 4 times: i = 1, 4, 7, 10. The step is 3, so it goes 1 → 4 → 7 → 10.
> The next value would be 13, which is past the stop value of 10.
> </details>

---

## 3. Tables: The One Data Structure

### 3.1 Why Only Tables?

Here's something that surprises beginners: Lua has **only one** data
structure. No arrays. No dictionaries. No structs. No classes. Just
**tables**.

A table is like a **backpack with numbered and named pockets**. You can put
things in pocket #1, pocket #2, and also in a pocket labeled "wallet" or
"keys". The same table can act as an array (numbered pockets) or a
dictionary (named pockets) or both.

Why did Lua's designers do this? Because it keeps the language small.
Instead of learning five different data structures with five different sets
of rules, you learn one. Tables are flexible enough to be arrays, objects,
modules, namespaces, and more. It's a "Swiss Army knife" approach.

### 3.2 Arrays: Numbered Pockets

An array is a table where the keys are sequential integers starting at 1:

```lua
local colors = {"red", "green", "blue"}

print(colors[1])     -- "red"
print(colors[2])     -- "green"
print(colors[3])     -- "blue"
print(#colors)       -- 3 (the length)
```

Notice that Lua arrays are **1-indexed**, not 0-indexed like C, Python, or
JavaScript. The first element is at index 1, not 0. This is a common source
of off-by-one errors for newcomers.

You can also create an array by assigning to numeric keys:

```lua
local arr = {}
arr[1] = "first"
arr[2] = "second"
arr[3] = "third"
```

### 3.3 Dictionaries: Named Pockets

A dictionary (or "hash map") is a table where the keys are strings (or any
value):

```lua
local player = {name = "hero", hp = 100, speed = 5}

print(player.name)      -- "hero"
print(player["hp"])     -- 100 (equivalent to player.hp)
print(player.speed)     -- 5
```

The dot syntax `player.name` is just shorthand for `player["name"]`. Use the
dot when the key is a valid identifier (starts with a letter, contains only
letters, digits, and underscores). Use brackets when the key is dynamic or
contains special characters:

```lua
local key = "hp"
print(player[key])      -- 100 (key is a variable)
print(player["max-hp"])  -- works with brackets, not with dot
```

### 3.4 Mixed Tables

A table can have both array and dictionary parts:

```lua
local mixed = {1, 2, 3, name = "test", hp = 100}

print(mixed[1])      -- 1
print(mixed[2])      -- 2
print(mixed.name)    -- "test"
print(mixed.hp)      -- 100
```

This is common in practice, but it's worth understanding that Lua internally
treats the two parts differently (more on this in a moment).

### 3.5 Insertion and Removal

```lua
local t = {}

table.insert(t, "a")           -- append: {a}
table.insert(t, "b")           -- append: {a, b}
table.insert(t, 1, "z")        -- insert at position 1: {z, a, b}

table.remove(t)                -- remove last: {z, a}
table.remove(t, 1)             -- remove at position 1: {a}
```

`table.insert` and `table.remove` operate on the **array part** of the
table. They shift elements as needed.

For building strings from arrays, `table.concat` is your friend:

```lua
local parts = {"hello", " ", "world"}
local s = table.concat(parts)           -- "hello world"
local s2 = table.concat(parts, ", ")    -- "hello ,  , world"
```

The second argument is a separator string inserted between elements.

### 3.6 Iterating: Walking Through a Table

There are two main ways to loop over a table:

**`ipairs`** — iterates the array part in order, stopping at the first `nil`:

```lua
local arr = {10, 20, nil, 40}
for i, v in ipairs(arr) do
  print(i, v)        -- 1 10, 2 20 (stops at the nil!)
end
```

**`pairs`** — iterates all keys, in no guaranteed order:

```lua
local dict = {a = 1, b = 2, c = 3}
for k, v in pairs(dict) do
  print(k, v)        -- order not guaranteed
end
```

If you need to iterate a dictionary in a specific order, collect the keys
first and sort them:

```lua
local keys = {}
for k in pairs(dict) do
  table.insert(keys, k)
end
table.sort(keys)
for _, k in ipairs(keys) do
  print(k, dict[k])
end
```

### 3.7 Common Table Patterns

**Sets** — checking if something is present:

```lua
local seen = {}
seen["enemy_42"] = true
if seen["enemy_42"] then
  -- present!
end
```

**Counting** — tallying occurrences:

```lua
local counts = {}
for _, v in ipairs(items) do
  counts[v] = (counts[v] or 0) + 1
end
-- counts["sword"] is now the number of swords in items
```

**2D grids** — a table of tables:

```lua
local grid = {}
for y = 1, 10 do
  grid[y] = {}
  for x = 1, 10 do
    grid[y][x] = 0
  end
end
-- grid[3][5] is the cell at row 3, column 5
```

#### Common Mistakes

```lua
-- Mistake 1: 0-indexed thinking
local arr = {"a", "b", "c"}
print(arr[0])     -- nil! Lua arrays start at 1

-- Mistake 2: Assuming pairs() has a defined order
for k, v in pairs({z = 1, a = 2, m = 3}) do
  -- Might print a, m, z or z, a, m or any other order.
  -- If you need order, use ipairs or sort the keys.
end

-- Mistake 3: Using ipairs on a dictionary
local dict = {a = 1, b = 2}
for i, v in ipairs(dict) do
  -- This won't iterate anything! ipairs only works on the array part.
end

-- Mistake 4: Modifying a table while iterating it with pairs
for k, v in pairs(t) do
  t[k] = nil    -- Dangerous! Behavior is undefined.
end
```

> **Why This Matters for Games:** Tables are *everything* in game scripting.
> An entity's state is a table. A list of enemies is a table. A tilemap is
> a table of tables. A configuration is a table. Once you're comfortable
> with tables, you can express any game data structure you need.

> **Check Your Understanding:** What does `#t` return for this table?
> ```lua
> local t = {1, 2, 3, nil, 5}
> print(#t)
> ```
> <details><summary>Answer</summary>
> It could be 3 or 5 — the Lua spec says the length of a table with "holes"
> (nil values in the middle) is undefined. In practice, LuaJIT will return
> one of the border positions. This is why `ipairs` stops at the first nil:
> it can't reliably detect the "end" of an array with holes. Avoid putting
> nils in the middle of arrays.
> </details>

---

## 4. Functions and Closures

### 4.1 Functions: Reusable Recipes

A **function** is a named (or anonymous) chunk of code that you can run
over and over with different inputs. Think of it as a recipe: you write it
once, and then you can cook the dish whenever you want.

```lua
-- A function that takes two numbers and returns their sum
local function add(a, b)
  return a + b
end

print(add(3, 5))     -- 8
print(add(10, 20))   -- 30
```

The `return` keyword sends a value back to whoever called the function.
A function can return **multiple values**:

```lua
local function min_max(arr)
  local lo, hi = arr[1], arr[1]
  for i = 2, #arr do
    if arr[i] < lo then lo = arr[i] end
    if arr[i] > hi then hi = arr[i] end
  end
  return lo, hi
end

local lo, hi = min_max({3, 1, 4, 1, 5, 9, 2, 6})
print(lo, hi)  -- 1, 9
```

You can also define anonymous functions and assign them to variables:

```lua
local mul = function(a, b)
  return a * b
end

print(mul(4, 5))  -- 20
```

And functions can take a **variable number of arguments** using `...`:

```lua
local function sum(...)
  local total = 0
  for _, v in ipairs({...}) do
    total = total + v
  end
  return total
end

print(sum(1, 2, 3, 4))  -- 10
```

The `...` captures all extra arguments. The `{...}` wraps them into a table
so you can iterate over them.

### 4.2 Closures: Functions That Remember

This is one of the most important concepts in Lua, so let's take our time.

A **closure** is a function that "remembers" the variables from the scope
where it was created, even after that scope has finished executing.

Let's build up to it step by step.

**Step 1:** A function that uses a local variable:

```lua
local function say_hello()
  local greeting = "hello"
  print(greeting)
end

say_hello()  -- "hello"
```

The variable `greeting` lives inside `say_hello`. When the function ends,
`greeting` is gone.

**Step 2:** What if we return a function that uses `greeting`?

```lua
local function make_greeter()
  local greeting = "hello"
  local function greet()
    print(greeting)
  end
  return greet
end

local greeter = make_greeter()
greeter()  -- "hello"
```

Wait — `greeting` was a local variable inside `make_greeter`. When
`make_greeter` returned, shouldn't `greeting` be gone?

**No.** Because `greet` is a closure — it captured `greeting`. The variable
stays alive as long as the closure exists. This is the key insight:
**a closure keeps its captured variables alive.**

**Step 3:** Now let's make it more interesting — a counter:

```lua
local function make_counter()
  local count = 0
  return function()
    count = count + 1
    return count
  end
end

local counter = make_counter()
print(counter())  -- 1
print(counter())  -- 2
print(counter())  -- 3
```

Each call to `counter()` increments `count` and returns the new value.
The variable `count` is **private** — no one outside the closure can see it
or modify it directly. You can only interact with it through the returned
function.

You can even create multiple independent counters:

```lua
local counter_a = make_counter()
local counter_b = make_counter()

print(counter_a())  -- 1
print(counter_a())  -- 2
print(counter_b())  -- 1 (independent!)
```

Each call to `make_counter()` creates a **new** `count` variable and a
**new** closure that captures it. They don't interfere with each other.

#### Common Mistakes

```lua
-- Mistake 1: Expecting the captured variable to be reset
local counter = make_counter()
print(counter())  -- 1
print(counter())  -- 2
-- The count is NOT reset between calls. It persists.

-- Mistake 2: Sharing a captured variable across multiple closures
local function make_multi()
  local count = 0
  local inc = function() count = count + 1; return count end
  local dec = function() count = count - 1; return count end
  return inc, dec
end

local inc, dec = make_multi()
print(inc())  -- 1
print(inc())  -- 2
print(dec())  -- 1 (both closures share the same count!)

-- Mistake 3: Capturing a loop variable (classic bug!)
local funcs = {}
for i = 1, 3 do
  funcs[i] = function() return i end
end
print(funcs[1]())  -- 3 (not 1!)
print(funcs[2]())  -- 3 (not 2!)
print(funcs[3]())  -- 3
-- All three closures captured the SAME variable i, which ended at 3.
-- Fix: create a new variable each iteration
for i = 1, 3 do
  local j = i
  funcs[i] = function() return j end
end
```

> **Why This Matters for Games:** Closures are the backbone of Ember's
> behavior system. When you write a behavior script, the methods you define
> are closures that capture the `self` table (the entity's state). This is
> how each entity can have its own health, position, and state — they're
> all captured by the closures in the prototype.

> **Check Your Understanding:** What does this print?
> ```lua
> local function make_adder(n)
>   return function(x)
>     return x + n
>   end
> end
>
> local add5 = make_adder(5)
> local add10 = make_adder(10)
>
> print(add5(3))   -- ?
> print(add10(3))  -- ?
> ```
> <details><summary>Answer</summary>
> `add5(3)` prints `8` (3 + 5) and `add10(3)` prints `13` (3 + 10).
> Each closure captured a different value of `n` — `add5` captured `5`,
> `add10` captured `10`. They're independent.
> </details>

---

### 4.3 Methods and the Colon Syntax

In Lua, the colon `:` is a convenient shorthand for working with tables
and functions together. It's syntactic sugar — a nicer way of writing
something you could also write out longhand.

**Longhand:**

```lua
local Player = {}

function Player.take_damage(self, amount)
  self.hp = self.hp - amount
end

local p = {hp = 100}
Player.take_damage(p, 30)
print(p.hp)  -- 70
```

**With colon syntax:**

```lua
local Player = {}

function Player:take_damage(amount)
  self.hp = self.hp - amount
end

local p = {hp = 100}
p:take_damage(30)
print(p.hp)  -- 70
```

The colon does two things:
- In the **definition** (`function Player:take_damage`), it adds an
  implicit first parameter called `self`.
- In the **call** (`p:take_damage(30)`), it passes `p` as the first argument.

So `p:take_damage(30)` is exactly the same as `Player.take_damage(p, 30)`.

The colon syntax is just a cleaner way to say "this function operates on a
table, and that table should be the first argument."

#### Common Mistakes

```lua
-- Mistake 1: Mixing dot and colon
function Player:take_damage(amount)
  self.hp = self.hp - amount
end

Player.take_damage(30)     -- Error! self is 30, amount is nil
Player:take_damage(30)     -- Works (self is Player)

-- Mistake 2: Forgetting self in the definition
function Player:take_damage(amount)
  hp = hp - amount        -- oops, hp is global! Should be self.hp
end
```

> **Why This Matters for Games:** You'll use the colon syntax constantly
> in Ember. Every behavior method is defined with `function M:update(dt)`
> and called with `self:update(dt)`. The `self` table holds the entity's
> state — its position, health, and any other data you store on it.

> **Check Your Understanding:** What is the output of this code?
> ```lua
> local t = {value = 10}
>
> function t:get()
>   return self.value
> end
>
> function t:set(v)
>   self.value = v
> end
>
> t:set(42)
> print(t:get())
> ```
> <details><summary>Answer</summary>
> `42`. `t:set(42)` passes `t` as `self` and `42` as `v`, so
> `self.value = 42` sets `t.value` to 42. Then `t:get()` returns
> `self.value`, which is 42.
> </details>

---

## 5. Metatables and Object-Oriented Programming

### 5.1 The Problem: How Do We Share Behavior?

Imagine you're writing a game with 100 enemies. Each enemy has a `take_damage`
method. You could write the method 100 times, once for each enemy — but
that's wasteful and hard to maintain.

What you want is: **define the method once, and have all enemies share it**.
This is the essence of object-oriented programming (OOP): shared behavior
with per-instance state.

Lua doesn't have built-in classes, but it gives you a powerful tool to build
them yourself: **metatables**.

### 5.2 Metatables: Rulebooks for Tables

A **metatable** is a table that defines custom behavior for another table.
Think of it as a rulebook: "if someone tries to do X to this table, do Y
instead."

You attach a metatable to a table with `setmetatable`:

```lua
local t = {}
local mt = {__index = some_other_table}
setmetatable(t, mt)
```

Now, if you try to access a key that doesn't exist in `t`, Lua will look it
up in `some_other_table` (because of the `__index` metamethod). This is the
key to sharing methods.

### 5.3 The `__index` Metamethod: Lookup on Missing Keys

`__index` is the most important metamethod for OOP. It fires when you
access a key that doesn't exist in the table:

```lua
local Animal = {}
Animal.__index = Animal

function Animal:speak()
  return "..."
end

function Animal.new(name)
  return setmetatable({name = name}, Animal)
end

local dog = Animal.new("dog")
print(dog:speak())  -- "..." (resolved through __index)
```

Here's what happens step by step:

1. `Animal.new("dog")` creates a table `{name = "dog"}` and sets its
   metatable to `Animal`.
2. When you call `dog:speak()`, Lua looks for `speak` in `dog`. It's not
   there (dog only has `name`).
3. Lua checks `dog`'s metatable for an `__index` field. It finds `Animal`.
4. Lua looks for `speak` in `Animal`. It finds the function!
5. The function is called with `self = dog`.

This is how all instances share the same methods without duplicating them.

### 5.4 The `__call` Metamethod: Making Tables Callable

`__call` lets you invoke a table as if it were a function:

```lua
local Callable = {}
Callable.__index = Callable
Callable.__call = function(self, x)
  return x * 2
end

local doubler = setmetatable({}, Callable)
print(doubler(21))  -- 42
```

Now `doubler(21)` works even though `doubler` is a table, not a function.
This is useful for creating callable objects, but you'll use `__index` far
more often.

### 5.5 The Full OOP Pattern

Here's the standard Lua OOP pattern, broken down step by step:

```lua
-- Step 1: Create the "class" table
local Class = {}

-- Step 2: Set __index so instances can find methods on the class
Class.__index = Class

-- Step 3: Define a constructor
function Class.new(...)
  -- Create a fresh table for this instance
  local obj = setmetatable({}, Class)
  -- Call the initializer (if defined)
  obj:init(...)
  return obj
end

-- Step 4: Define methods
function Class:init(value)
  self.value = value
end

function Class:get()
  return self.value
end
```

Let's trace through what happens:

1. `Class.new(10)` creates a new empty table `{}` and sets its metatable
   to `Class`.
2. `obj:init(10)` calls `Class.init(obj, 10)`, which sets `obj.value = 10`.
3. Later, `obj:get()` looks up `get` in `obj` (not found), then in
   `Class` via `__index` (found!), and calls it with `self = obj`.

**Inheritance** is done by chaining metatables:

```lua
local SubClass = setmetatable({}, {__index = Class})
SubClass.__index = SubClass

function SubClass:init(value, extra)
  Class.init(self, value)    -- call the parent's init
  self.extra = extra
end

function SubClass:get()
  return Class.get(self) + self.extra
end

local obj = SubClass.new(10, 5)
print(obj:get())  -- 15
```

When `obj:get()` is called:
1. Lua looks for `get` in `obj` — not found.
2. Lua looks in `SubClass` (via `obj`'s metatable's `__index`) — found!
3. `SubClass:get` calls `Class.get(self)`, which looks for `get` in `Class`
   — found!
4. The result is `10 + 5 = 15`.

### 5.6 How Ember Uses Metatables

Ember's behavior system uses this exact pattern. Here's what happens behind
the scenes:

```lua
-- Your script returns a prototype table:
local M = {}
function M:update(dt) ... end
return M

-- The engine does this (simplified):
local prototype = load_script()        -- your returned M
local metatable = {__index = prototype}

-- Each instance gets its own table with the shared metatable:
local self = setmetatable({}, metatable)
self.__entity = <entity handle>        -- stamped by the engine

-- Method lookup: self:update(dt) resolves through metatable.__index
```

This means:

- **All instances share one prototype** (memory efficient — you don't
  copy the methods for every enemy).
- **Instance state lives on `self`** (per-actor data — each enemy has its
  own health, position, etc.).
- **Hot-reload just repoints `__index`** at a new prototype; instances keep
  their state. This is why you can edit a Lua script and see changes
  immediately without losing the game state.

#### Common Mistakes

```lua
-- Mistake 1: Forgetting to set __index
local Class = {}
-- Oops, forgot Class.__index = Class
function Class:foo() return "foo" end

local obj = setmetatable({}, Class)
print(obj:foo())  -- Error! attempt to call a nil value

-- Mistake 2: Forgetting setmetatable in the constructor
function Class.new()
  return {}  -- Oops, no metatable! Methods won't be found.
end

-- Mistake 3: Not calling the parent's init in inheritance
function SubClass:init(value, extra)
  -- Oops, forgot Class.init(self, value)
  self.extra = extra
end

-- Mistake 4: Confusing the class with an instance
print(Class.get())  -- Error! Class has no 'value' field.
                    -- You need an instance: Class.new(10):get()
```

> **Why This Matters for Games:** Every behavior script you write for Ember
> is a prototype table. The engine creates instances of it using metatables.
> When you write `function M:update(dt)`, you're defining a method on the
> prototype. When the engine calls `self:update(dt)` on an instance, it
> finds your method through the metatable's `__index`. Understanding this
> helps you debug issues where methods seem to "not exist" — usually it's a
> missing `__index` or a forgotten `setmetatable`.

> **Check Your Understanding:** What does this print?
> ```lua
> local A = {}
> A.__index = A
> function A:greet() return "hello from A" end
>
> local B = setmetatable({}, {__index = A})
>
> local obj = setmetatable({}, B)
> print(obj:greet())
> ```
> <details><summary>Answer</summary>
> "hello from A". Here's the chain:
> 1. `obj:greet()` looks for `greet` in `obj` — not found.
> 2. Lua looks in `B` (via `obj`'s metatable's `__index`) — not found.
> 3. Lua looks in `A` (via `B`'s metatable's `__index`) — found!
> 4. The function is called with `self = obj`.
> </details>

---

## 6. Coroutines: Pausing and Resuming Work

### 6.1 The Problem: Work That Takes Multiple Frames

In a game, some things don't happen instantly. A cutscene might play out
over several seconds. An enemy might wait, then attack, then wait again.
A timed sequence might spawn enemies at intervals.

You *could* manage this with a state machine and timers in your `update`
loop, but that gets messy fast. **Coroutines** offer a cleaner way: you
write the sequence as a straight line of code, and **yield** (pause) at
the points where you want to wait.

### 6.2 What Is a Coroutine?

A **coroutine** is a function that can pause itself and resume later,
remembering exactly where it left off and what its local variables were.
Think of it as a **bookmark in a book**: you can close the book, come back
tomorrow, and pick up exactly where you left off.

Coroutines are **cooperative**, not preemptive. This means a coroutine
runs until it explicitly yields — it can't be interrupted by another
coroutine. Only one coroutine runs at a time.

### 6.3 Creating and Resuming Coroutines

```lua
local co = coroutine.create(function(a, b)
  print("start", a, b)
  coroutine.yield(a + b)    -- pause, send back a + b
  print("resumed")
  return a * b             -- finish, send back a * b
end)

-- First resume: runs until the first yield
local ok, val = coroutine.resume(co, 10, 20)
print(ok, val)   -- true, 30

-- Second resume: runs until return
local ok2, val2 = coroutine.resume(co)
print(ok2, val2) -- true, 200
```

Here's what happens:

1. `coroutine.create` creates a coroutine but doesn't run it yet.
2. The first `coroutine.resume(co, 10, 20)` starts the coroutine with
   `a = 10, b = 20`. It prints "start 10 20", then hits `yield(30)`.
   The resume returns `true, 30`.
3. The second `coroutine.resume(co)` continues from the yield. It prints
   "resumed", then hits `return 200`. The resume returns `true, 200`.
4. After the coroutine returns, it's **dead** and can't be resumed again.

### 6.4 Coroutines in Game Code

Here's a practical example: a behavior that waits, then moves an actor:

```lua
local M = {}

function M:start()
  self.co = coroutine.create(function()
    coroutine.yield(1.0)   -- wait 1 second
    log.info("1 second passed")
    coroutine.yield(0.5)   -- wait 0.5 seconds
    log.info("done waiting")
    actor.move_by(self, 100, 0)
  end)
end

function M:update(dt)
  if self.co and coroutine.status(self.co) ~= "dead" then
    coroutine.resume(self.co, dt)
  end
end

return M
```

The trick is that `dt` (delta time) is passed to the coroutine on each
resume. The coroutine yields a number representing how many seconds it
wants to wait. The `update` function accumulates the yielded time and
resumes the coroutine when enough time has passed.

A more complete pattern:

```lua
function M:update(dt)
  if self.co and coroutine.status(self.co) ~= "dead" then
    local wait_time = self.accumulated or 0
    wait_time = wait_time + dt
    local ok, requested = coroutine.resume(self.co, wait_time)
    if ok and requested and wait_time < requested then
      self.accumulated = wait_time  -- keep waiting
    else
      self.accumulated = nil         -- done waiting, reset
    end
  end
end
```

### 6.5 Coroutine States

A coroutine can be in one of four states:

| State | Meaning |
|---|---|
| `"suspended"` | Created or yielded, can be resumed |
| `"running"` | Currently executing |
| `"dead"` | Finished, cannot be resumed |
| `"normal"` | Another coroutine is running (this one is the resumer) |

```lua
print(coroutine.status(co))  -- "suspended", "running", "dead", or "normal"
```

### 6.6 When to Use Coroutines

Coroutines are great for:

- **Timed sequences:** "wait 2 seconds, then spawn an enemy."
- **Cutscenes:** A series of timed actions.
- **State machines:** Each state is a coroutine that yields on exit.
- **Async-like patterns:** Yield while waiting for a condition.

But they're not always the right tool. For most game logic, prefer the
`update` loop with explicit state. Coroutines add complexity and are
harder to debug — if a coroutine yields and never resumes, it just sits
there silently.

#### Common Mistakes

```lua
-- Mistake 1: Resuming a dead coroutine
local co = coroutine.create(function() return 42 end)
coroutine.resume(co)        -- true, 42
coroutine.resume(co)        -- false, "cannot resume dead coroutine"

-- Mistake 2: Not checking the status before resuming
function M:update(dt)
  coroutine.resume(self.co, dt)  -- Error if self.co is dead!
end

-- Mistake 3: Forgetting that yield passes values to resume
local co = coroutine.create(function()
  local x = coroutine.yield(10)  -- x is whatever resume passes
  print(x)
end)
coroutine.resume(co)      -- starts, yields 10
coroutine.resume(co, 99)  -- resumes, x = 99, prints 99

-- Mistake 4: Using coroutines for everything
-- If you find yourself with 50 coroutines, consider a state machine instead.
```

> **Why This Matters for Games:** Coroutines are perfect for cutscenes,
> timed attacks, and any sequence that spans multiple frames. Instead of
> managing a bunch of timers and state variables, you write the sequence
> linearly and yield at the waiting points. This makes the code much
> easier to read and maintain.

> **Check Your Understanding:** What does this print?
> ```lua
> local co = coroutine.create(function()
>   for i = 1, 3 do
>     coroutine.yield(i)
>   end
>   return "done"
> end)
>
> print(coroutine.resume(co))  -- ?
> print(coroutine.resume(co))  -- ?
> print(coroutine.resume(co))  -- ?
> print(coroutine.resume(co))  -- ?
> ```
> <details><summary>Answer</summary>
> ```
> true, 1
> true, 2
> true, 3
> true, done
> ```
> Each resume runs until the next yield (or the return). The first three
> resumes yield 1, 2, 3. The fourth resume hits the `return "done"`, so
> it returns `true, "done"`. A fifth resume would return `false, "cannot
> resume dead coroutine"`.
> </details>

---

## 7. Where to Go Next

You now understand the core of Lua:

- **Variables and types** — the labeled boxes and what you can put in them.
- **Tables** — the one data structure that does everything.
- **Functions and closures** — reusable recipes that remember their kitchen.
- **Metatables and OOP** — how to share behavior across instances.
- **Coroutines** — how to pause and resume work over multiple frames.

These are the building blocks of every Ember behavior script. You don't
need to memorize everything — you can always come back to this guide as a
reference. The important thing is that you understand the *intuition* behind
each concept.

For the autogenerated API stubs (for LuaLS/EmmyLua), see
[`meta/ember.lua`](https://github.com/jesusalcaladev/ember-engine/blob/main/meta/ember.lua).

---

> **Next:** Ready to see how Lua integrates with the Ember engine? Continue to
> [Lua in Ember: The Engine API](ember-lua.md) for the engine-specific guide
> covering the VM, sandbox, full API reference, and a complete example.
