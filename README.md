# Botch

![Botch Demo](demo.gif)

Botch is a stack based concatenative programming language. It's end goal is to be compiled to Batch. It currently has an interpreter written in Teal (a typed dialect of Lua).

## Usage

First you'll need the Teal compiler. You can install it using `luarocks install tl`.

Then you'll need to clone this git repo:
```shell
git clone --recurse-submodules https://github.com/icy-lava/botch.git
cd botch

# Run an example script
tl run botch.tl run example/hello.bot
# Run the Read Evaluate Print Loop (REPL)
tl run botch.tl repl
```

## Examples

The examples folder has some programs written, but here's some code.

#### Hello world:

```shell
# Print "Hello world!"
start:
    "Hello world" write-line
    
    # When we reach the end of file, there's an automatic return which will end execution,
    # however, it is good practice to explicitly exit like this:
    exit
```

1. Everything from the `#` symbol to the end of the line is a comment, it will not be executed.
2. `start:` is a label and it is the entrypoint of the program.
3. The execution will then advance to `"Hello world"`, this literal will be pushed onto the stack as a string (all values in Botch are strings).
4. Then the `write-line` built-in function will be called, this function will consume the string on the stack and write it to standard output.
5. Finally, the `exit` built-in will terminate the program.

It's important to note that botch doesn't care about whitespace, except when dealing with line comments, dealing with strings, and to seperate the symbols. This is the same program written in 1 line:

```shell
start: "Hello world" write-line exit
```

#### Counting:

```shell
# Print numbers 1 through 10
start:
    0 10
start-loop:
    # i n
    swap
    # n i
    ++ dup write-line
    swap -- dup
    # i n-1
    @start-loop cond-jump
    # i 0
    exit
```

1. We first push the numbers 1 and 10 onto the stack. 10 is the second number pushed, so it is on top of the stack.
2. We go past the `start-loop` label. A label on it's own is a noop.
3. We then swap the top 2 values on the stack, so now 0 is on top, 10 is below that.
4. We increment the top value by 1, we duplicate that value, which gets put on the stack, but then gets consumed by `write-line`.
5. We swap the values again, now 10 is on top again. We decrement it by one, now we have a 9. We duplicate this 9.
6. An identifier that starts with an `@` (in this case `@start-loop`) is an address that gets pushed onto the stack. This can be used by a jump instruction to move execution of the program to the position of that label. After the address is pushed onto the stack, we do a conditional jump, which jumps to an address only if the second value from the top of the stack is not 0.
7. Since we have a 9 a the condition, we jump back to the start-loop label. We repeat that process (except for pushing the 0 and 10 values) until we have a 0 in that spot in the program, at which point we will pass the label and exit the program.

Just to bring home the previous remark about whitespace, here's the same program in 1 line:

```shell
start: 0 10 start-loop: swap ++ dup write-line swap -- dup @start-loop cond-jump exit
```

#### `store`, `load`, `trace`

```shell
start:
    1 2 3
    trace # stack (3): "1", "2", "3"
    
    store
    trace # stack (3): "3", "1", "2"
    
    load
    trace # stack (3): "1", "2", "3"
    
    exit
```

#### Define and call a function

```shell
# Defining and calling a function

say-hello:
    # ... str
    "Hello " swap concat
    # ... str
    "!" concat write-line
    # ...
    return # If we don't return, we'll execute start again

start:
    "world" say-hello # Writes "Hello world!"
    exit
```

## Learning

To learn what built-ins are available to you, take a look at `botch.tl`.
