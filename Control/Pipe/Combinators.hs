{-# LANGUAGE ScopedTypeVariables #-}
-- | Basic pipe combinators.
module Control.Pipe.Combinators (
  -- ** Control operators
  tryAwait,
  forP,
  -- ** Producers
  fromList,
  -- ** Composition
  ($$),
  -- ** Folds
  -- | Folds are pipes that consume all their input and return a value. Some of
  -- them, like 'fold1', do not return anything when they don't receive any
  -- input at all. That means that the upstream return value will be returned
  -- instead.
  --
  -- Folds are normally used as 'Consumer's, but they are actually polymorphic
  -- in the output type, to encourage their use in the implementation of
  -- higher-level combinators.
  fold,
  fold1,
  consume,
  consume1,
  -- ** List-like pipe combinators
  -- The following combinators are analogous to the corresponding list
  -- functions, when the stream of input values is thought of as a (potentially
  -- infinite) list.
  take,
  drop,
  takeWhile,
  takeWhile_,
  dropWhile,
  intersperse,
  groupBy,
  filter,
  -- ** Other combinators
  pipeList,
  nullP,
  feed,
  ) where

import Control.Applicative
import Control.Monad
import Control.Pipe
import Data.Maybe
import Prelude hiding (until, take, drop, concatMap, filter, takeWhile, dropWhile, catch)

($$) :: Monad m => Pipe a b r m r -> Pipe b c r m s -> Pipe a c r m s
($$) = (>+>)

-- | Like 'await', but returns @Just x@ when the upstream pipe yields some value
-- @x@, and 'Nothing' when it terminates.
--
-- Further calls to 'tryAwait' after upstream termination will keep returning
-- 'Nothing', whereas calling 'await' will terminate the current pipe
-- immediately.
tryAwait :: Monad m => Pipe a b u m (Either u a)
tryAwait = Await (return . Right) (either rethrow (return . Left))
  where
    rethrow e = Throw (Left e) tryAwait []

-- | Execute the specified pipe for each value in the input stream.
--
-- Any action after a call to 'forP' will be executed when upstream terminates.
forP :: Monad m => (a -> Pipe a b u m r) -> Pipe a b u m u
forP f = tryAwait >>= either return (\a -> f a >> forP f)

-- | Successively yield elements of a list.
fromList :: Monad m => [a] -> Pipe x a u m ()
fromList = mapM_ yield

-- | A pipe that terminates immediately.
nullP :: Monad m => Pipe a b u m ()
nullP = return ()

-- | A fold pipe. Apply a binary function to successive input values and an
-- accumulator, and return the final result.
fold :: Monad m => (b -> a -> b) -> b -> Pipe a x u m b
fold f = go
  where
    go x = tryAwait >>= either (\_ -> return x) (let y = f x in y `seq` go . y)

-- | A variation of 'fold' without an initial value for the accumulator. This
-- pipe doesn't return any value if no input values are received.
fold1 :: Monad m => (a -> a -> a) -> Pipe a x u m a
fold1 f = tryAwait >>= either defer (fold f)

-- | Accumulate all input values into a list.
consume :: Monad m => Pipe a x u m [a]
consume = pipe (:) >+> (fold (.) id <*> pure [])

-- | Accumulate all input values into a non-empty list.
consume1 :: Monad m => Pipe a x u m [a]
consume1 = pipe (:) >+> (fold1 (.) <*> pure [])

-- | Act as an identity for the first 'n' values, then terminate.
take :: Monad m => Int -> Pipe a a u m ()
take n = replicateM_ n $ await >>= yield

-- | Remove the first 'n' values from the stream, then act as an identity.
drop :: Monad m => Int -> Pipe a a u m r
drop n = replicateM_ n await >> idP

-- | Apply a function with multiple return values to the stream.
pipeList :: Monad m => (a -> [b]) -> Pipe a b u m r
pipeList f = forever $ await >>= mapM_ yield . f

-- | Act as an identity until as long as inputs satisfy the given predicate.
-- Return the first element that doesn't satisfy the predicate.
takeWhile :: Monad m => (a -> Bool) -> Pipe a a u m a
takeWhile p = go
  where
    go = await >>= \x -> if p x then yield x >> go else return x

-- | Variation of 'takeWhile' returning @()@.
takeWhile_ :: Monad m => (a -> Bool) -> Pipe a a u m ()
takeWhile_ = void . takeWhile

-- | Remove inputs as long as they satisfy the given predicate, then act as an
-- identity.
dropWhile :: Monad m => (a -> Bool) -> Pipe a a a m r
dropWhile p = (takeWhile p >+> discard) >>= yield >> idP

-- | Yield Nothing when an input satisfying the predicate is received.
intersperse :: Monad m => (a -> Bool) -> Pipe a (Maybe a) u m r
intersperse p = forever $ do
  x <- await
  when (p x) $ yield Nothing
  yield $ Just x

-- | Group input values by the given predicate.
groupBy :: Monad m => (a -> a -> Bool) -> Pipe a [a] () m r
groupBy p = streaks >+> createGroups
  where
    streaks = await >>= \x -> yield (Just x) >> streaks' x
    streaks' x = do
      y <- await
      unless (p x y) $ yield Nothing
      yield $ Just y
      streaks' y
    createGroups = forever $
      takeWhile_ isJust >+>
      pipe fromJust >+>
      (consume1 >>= yield)

-- | Remove values from the stream that don't satisfy the given predicate.
filter :: Monad m => (a -> Bool) -> Pipe a a u m r
filter p = forever $ takeWhile_ p

-- | Feed an input element to a pipe.
feed :: Monad m => a -> Pipe a b u m r -> Pipe a b u m r

-- this could be implemented as
-- feed x p = (yield x >> idP) >+> p
-- but this version is more efficient
feed _ (Pure r w) = Pure r w
feed a (Yield x p w) = Yield x (feed a p) w
feed a (Throw e p w) = Throw e (feed a p) w
feed a (M s m h) = M s (liftM (feed a) m) (feed a . h)
feed a (Await k _) = k a
