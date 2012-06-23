This library offers an abstraction similar in scope to
iteratees/enumerators/enumeratees, but with different characteristics and
naming conventions.

[![Continuous Integration status][status-png]][status]

Difference with traditional iteratees:

* **Simpler semantics**: There is only one data type (`Pipe`), two primitives
  (`await` and `yield`), and only one way to compose `Pipe`s (`>+>`).  In fact,
  (`>+>`) is just convenient syntax for the composition operator in `Category`.
  Most pipes can be implemented just using the `Monad` instance and
  composition.

* **Different naming conventions**: Enumeratees are called `Pipe`s, Enumerators
  are `Producer`s, and Iteratees are `Consumer`s.  `Producer`s and `Consumer`s
  are just type synonyms for `Pipe`s with either the input or output end
  closed.

* **Pipes form a Category**: that means that composition is associative, and
  that there is an identity `Pipe`.

* **"Vertical" concatenation works on every `Pipe`**: (`>>`),
  concatenates `Pipe`s. Since everything is a `Pipe`, you can use it to
  concatenate `Producer`s, `Consumer`s, and even intermediate `Pipe` stages.
  Vertical concatenation can be combined with composition to create elaborate
  combinators, without the need of executing pipes in "passes" or resuming
  partially executed pipes.

This library is based on the [pipes][1] package by Gabriel Gonzalez.

 [status-png]: https://secure.travis-ci.org/pcapriotti/pipes-core.png?branch=devel
 [status]: http://travis-ci.org/pcapriotti/pipes-core?branch=devel
 [1]: http://hackage.haskell.org/package/pipes
