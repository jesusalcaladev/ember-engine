# Learning Lua: Language Fundamentals

This guide takes you from zero Lua knowledge to writing Ember behaviors. It
covers the language fundamentals and the features that matter most for game
scripting.

The guide is progressive: each section builds on the previous one, with
examples that go from "Hello World" to a complete game behavior.

---

## Table of Contents

1. [Basic Syntax](#1-basic-syntax)
2. [Tables: The One Data Structure](#2-tables-the-one-data-structure)
3. [Functions and Closures](#3-functions-and-closures)
4. [Metatables and Object-Oriented Programming](#4-metatables-and-object-oriented-programming)
5. [Coroutines](#5-coroutines)

---

## 1. Basic Syntax

Lua is a small language. The entire syntax fits on a few pages.

### Variables and Types

```lua
-- Lua has 8 basic types:
local n = 42              -- number (double-precision float)
local s = "hello"         -- string
local b = true            -- boolean
local t = {1, 2, 3}       -- table
local f = function() end  -- function
local nil_val = nil       -- nil (absence of a value)

-- `local` is scoped to the block. Without `local`, a variable is global.
x = 10                    -- global (avoid this in behaviors)
local y = 20              -- local (preferred)
```

### Numbers

All Lua numbers are doubles (64-bit floats). There is no integer type, though
Lua 5.3+ has integer division and bitwise operators. Ember uses **LuaJIT**
(Lua 5.1), so:

```lua
local a = 10 / 3     -- 3.3333333333333335 (float division)
local b = 10 // 3    -- NOT available in LuaJIT (Lua 5.3+ only)
local c = 10 % 3     -- 1 (modulo)
local d = 2^10       -- 1024 (exponentiation)
```

For game math, you will mostly use `f32` values passed to/from the engine.
LuaJIT's numbers are doubles, but the engine converts at the boundary.

### Strings

```lua
local s = "hello"
local t = 'world'                    -- single quotes work too
local u = s .. " " .. t              -- concatenation: "hello world"
local n = #s                         -- length: 5
local f = string.format("%d + %d = %d", 1, 2, 3)  -- "1 + 2 = 3"
local rep = string.rep("ab", 3)      -- "ababab"
local sub = string.sub(s, 2, 4)      -- "ell"
local upper = string.upper(s)        -- "HELLO"
```

Strings are immutable. Concatenation creates a new string each time, so in
hot loops, prefer `table.concat` or build strings sparingly.

### Booleans and nil

```lua
local a = true
local b = false
local c = nil

-- Only `false` and `nil` are falsy. Everything else is truthy.
if 0 then print("0 is truthy!") end     -- prints!
if "" then print("empty string is truthy!") end  -- prints!
if nil then print("never") end          -- never prints
```

### Control Flow

```lua
-- if / elseif / else
if x > 0 then
  print("positive")
elseif x < 0 then
  print("negative")
else
  print("zero")
end

-- while
local i = 0
while i < 10 do
  i = i + 1
end

-- numeric for
for i = 1, 10 do          -- 1 to 10, inclusive
  print(i)
end
for i = 10, 1, -2 do      -- 10, 8, 6, 4, 2
  print(i)
end

-- generic for (iterating tables)
for k, v in pairs(t) do
  print(k, v)
end
for i, v in ipairs(t) do  -- array part only, in order
  print(i, v)
end
```

### Comments

```lua
-- single line
--[[ multi
     line ]]
```

---

## 2. Tables: The One Data Structure

Tables are Lua's only data structure. They serve as arrays, dictionaries,
objects, and modules.

### Array Part and Hash Part

```lua
-- Array (sequential integer keys starting at 1)
local arr = {10, 20, 30}
print(arr[1])        -- 10
print(#arr)          -- 3 (length)

-- Dictionary (any keys)
local dict = {name = "player", hp = 100}
print(dict.name)     -- "player"
print(dict["hp"])    -- 100

-- Mixed
local mixed = {1, 2, 3, name = "test"}
print(mixed[1])      -- 1
print(mixed.name)    -- "test"
```

### Insertion and Removal

```lua
local t = {}
table.insert(t, "a")           -- append: {a}
table.insert(t, 1, "b")        -- insert at position 1: {b, a}
table.remove(t)                -- remove last: {b}
table.remove(t, 1)             -- remove at position 1: {}

-- table.concat for arrays of strings/numbers
local parts = {"hello", " ", "world"}
local s = table.concat(parts)  -- "hello world"
local s2 = table.concat(parts, ", ")  -- "hello ,  , world"
```

### Iterating

```lua
-- ipairs: array part, in order, stops at first gap
local arr = {10, 20, nil, 40}
for i, v in ipairs(arr) do
  print(i, v)        -- 1-10, 2-20 (stops at nil)
end

-- pairs: all keys, unordered
local dict = {a = 1, b = 2, c = 3}
for k, v in pairs(dict) do
  print(k, v)        -- order not guaranteed
end

-- Ordered iteration (when you need it)
local keys = {"a", "b", "c"}
for _, k in ipairs(keys) do
  print(k, dict[k])
end
```

### Common Table Patterns

```lua
-- Set (lookup table)
local seen = {}
seen[x] = true
if seen[x] then -- present end

-- Counting
local counts = {}
for _, v in ipairs(items) do
  counts[v] = (counts[v] or 0) + 1
end

-- 2D grid
local grid = {}
for y = 1, 10 do
  grid[y] = {}
  for x = 1, 10 do
    grid[y][x] = 0
  end
end
```

---

## 3. Functions and Closures

Functions are first-class values in Lua. They can be assigned, passed as
arguments, and returned from other functions.

### Defining Functions

```lua
-- Named function
local function add(a, b)
  return a + b
end

-- Anonymous function assigned to a variable
local mul = function(a, b)
  return a * b
end

-- Multiple return values
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

-- Varargs
local function sum(...)
  local total = 0
  for _, v in ipairs({...}) do
    total = total + v
  end
  return total
end
print(sum(1, 2, 3, 4))  -- 10
```

### Closures

A closure is a function that captures variables from its enclosing scope:

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

Closures are the backbone of Lua OOP and Ember's behavior system. Each
behavior instance's `self` table is captured by the closures defined in the
prototype.

### Methods and the Colon Syntax

The colon `:` is syntactic sugar for passing the table as `self`:

```lua
local Player = {}
Player.__index = Player

function Player.new(x, y)
  return setmetatable({x = x, y = y, hp = 100}, Player)
end

-- Colon definition: self is the first parameter
function Player:take_damage(amount)
  self.hp = self.hp - amount
  if self.hp <= 0 then
    self:die()
  end
end

function Player:die()
  print("player died at " .. self.x .. ", " .. self.y)
end

-- Colon call: passes the table as self
local p = Player.new(10, 20)
p:take_damage(30)       -- equivalent to Player.take_damage(p, 30)
p:take_damage(80)       -- triggers die()
```

---

## 4. Metatables and Object-Oriented Programming

Metatables let you define custom behavior for tables: what happens when you
index a missing key, call a table, add two tables, etc.

### The `__index` Metamethod

`__index` is the most important metamethod for OOP. It fires when you access
a missing key:

```lua
local Animal = {}
Animal.__index = Animal

function Animal.new(name)
  return setmetatable({name = name}, Animal)
end

function Animal:speak()
  return "..."
end

local dog = Animal.new("dog")
print(dog:speak())  -- "..." (resolved through __index)
```

### The `__call` Metamethod

`__call` lets you invoke a table as a function:

```lua
local Callable = {}
Callable.__index = Callable
Callable.__call = function(self, x)
  return x * 2
end

local doubler = setmetatable({}, Callable)
print(doubler(21))  -- 42
```

### Full OOP Pattern

Here is the standard Lua OOP pattern used throughout Ember:

```lua
local Class = {}
Class.__index = Class

function Class.new(...)
  local obj = setmetatable({}, Class)
  obj:init(...)
  return obj
end

function Class:init(value)
  self.value = value
end

function Class:get()
  return self.value
end

-- Inheritance
local SubClass = setmetatable({}, {__index = Class})
SubClass.__index = SubClass

function SubClass:init(value, extra)
  Class.init(self, value)
  self.extra = extra
end

function SubClass:get()
  return Class.get(self) + self.extra
end

local obj = SubClass.new(10, 5)
print(obj:get())  -- 15
```

### How Ember Uses Metatables

Ember's behavior system uses metatables to share a prototype across all
instances of a script:

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
- **All instances share one prototype** (memory efficient).
- **Instance state lives on `self`** (per-actor data).
- **Hot-reload just repoints `__index`** at a new prototype; instances keep
  their state.

---

## 5. Coroutines

Coroutines are Lua's cooperative multitasking. A coroutine can yield control
and resume later, preserving its local state.

### Creating and Running Coroutines

```lua
local co = coroutine.create(function(a, b)
  print("start", a, b)
  coroutine.yield(a + b)
  print("resumed")
  return a * b
end)

local ok, val = coroutine.resume(co, 10, 20)
print(ok, val)   -- true, 30

local ok2, val2 = coroutine.resume(co)
print(ok2, val2) -- true, 200
```

### Coroutines in Game Code

Coroutines are useful for timed sequences, cutscenes, and AI that spans
multiple frames:

```lua
local M = {}

function M:start()
  -- Start a coroutine that waits, then does something
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
    -- Pass dt as the "time elapsed" signal
    coroutine.resume(self.co, dt)
  end
end

return M
```

### Coroutine States

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

### When to Use Coroutines

- **Timed sequences:** "wait 2 seconds, then spawn an enemy."
- **Cutscenes:** A series of timed actions.
- **State machines:** Each state is a coroutine that yields on exit.
- **Async-like patterns:** Yield while waiting for a condition.

For most game logic, prefer the `update` loop with explicit state. Coroutines
add complexity and are harder to debug.

---

## Summary

You now know:

- Lua's core syntax: variables, tables, functions, closures, metatables.
- How Ember uses metatables to share prototypes across behavior instances.
- How the engine drives the lifecycle: `start`, `update`, `fixed_update`,
  `on_signal`, `on_destroy`.
- The full API surface: `actor`, `input`, `vec2`, `math`, `rand`, `noise`,
  `log`, `sm`, `world`, `steer`.
- How hot-reloading preserves instance state while swapping methods.
- How errors are isolated (a broken script is a logged line, not a crash).

For the autogenerated API stubs (for LuaLS/EmmyLua), see
[`meta/ember.lua`](https://github.com/jesusalcaladev/ember-engine/blob/main/meta/ember.lua).

---

> **Next:** Ready to see how Lua integrates with the Ember engine? Continue to
> [Lua in Ember: The Engine API](ember-lua.md) for the engine-specific guide
> covering the VM, sandbox, full API reference, and a complete example.
