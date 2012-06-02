{-# LANGUAGE ScopedTypeVariables #-}
-- | Basic pipe combinators.
module Control.Pipe.Combinators (
  -- ** Control operators
  tryAwait,
  forP,
  -- ** Composition
  ($$),
  -- ** Producers
  fromList,
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
import Control.Pipe.Exception
import Data.Maybe
import Prelude hiding (until, take, drop, concatMap, filter, takeWhile, dropWhile, catch)

-- | Like 'await', but returns @Just x@ when the upstream pipe yields some value
-- @x@, and 'Nothing' when it terminates.
--
-- Further calls to 'tryAwait' after upstream termination will keep returning
-- 'Nothing', whereas calling 'await' will terminate the current pipe
-- immediately.
tryAwait :: Monad m => Pipe a b m (Maybe a)
tryAwait = catch (Just <$> await) $ \(_ :: BrokenPipe) -> return Nothing

-- | Execute the specified pipe for each value in the input stream.
--
-- Any action after a call to 'forP' will be executed when upstream terminates.
forP :: Monad m => (a -> Pipe a b m r) -> Pipe a b m ()
forP f = tryAwait >>= maybe (return ()) (\a -> f a >> forP f)

-- | Connect producer to consumer, ignoring producer return value.
infixr 5 $$
($$) :: Monad m => Pipe x a m r' -> Pipe a y m r -> Pipe x y m (Maybe r)
p1 $$ p2 = (p1 >> return Nothing) >+> fmap Just p2

-- | Successively yield elements of a list.
fromList :: Monad m => [a] -> Pipe x a m ()
fromList = mapM_ yield

-- | A pipe that terminates immediately.
nullP :: Monad m => Pipe a b m ()
nullP = return ()

-- | A fold pipe. Apply a binary function to successive input values and an
-- accumulator, and return the final result.
fold :: Monad m => (b -> a -> b) -> b -> Pipe a x m b
fold f = go
  where
    go x = tryAwait >>= maybe (return x) (let y = f x in y `seq` go . y)

-- | A variation of 'fold' without an initial value for the accumulator. This
-- pipe doesn't return any value if no input values are received.
fold1 :: Monad m => (a -> a -> a) -> Pipe a x m a
fold1 f = tryAwait >>= maybe discard (fold f)

-- | Accumulate all input values into a list.
consume :: Monad m => Pipe a x m [a]
consume = pipe (:) >+> (fold (.) id <*> pure [])

-- | Accumulate all input values into a non-empty list.
consume1 :: Monad m => Pipe a x m [a]
consume1 = pipe (:) >+> (fold1 (.) <*> pure [])

-- | Act as an identity for the first 'n' values, then terminate.
take :: Monad m => Int -> Pipe a a m ()
take n = replicateM_ n $ await >>= yield

-- | Remove the first 'n' values from the stream, then act as an identity.
drop :: Monad m => Int -> Pipe a a m r
drop n = replicateM_ n await >> idP

-- | Apply a function with multiple return values to the stream.
pipeList :: Monad m => (a -> [b]) -> Pipe a b m r
pipeList f = forever $ await >>= mapM_ yield . f

-- | Act as an identity until as long as inputs satisfy the given predicate.
-- Return the first element that doesn't satisfy the predicate.
takeWhile :: Monad m => (a -> Bool) -> Pipe a a m a
takeWhile p = go
  where
    go = await >>= \x -> if p x then yield x >> go else return x

-- | Variation of 'takeWhile' returning @()@.
takeWhile_ :: Monad m => (a -> Bool) -> Pipe a a m ()
takeWhile_ = void . takeWhile

-- | Remove inputs as long as they satisfy the given predicate, then act as an
-- identity.
dropWhile :: Monad m => (a -> Bool) -> Pipe a a m r
dropWhile p = (takeWhile p >+> discard) >>= yield >> idP

-- | Yield Nothing when an input satisfying the predicate is received.
intersperse :: Monad m => (a -> Bool) -> Pipe a (Maybe a) m r
intersperse p = forever $ do
  x <- await
  when (p x) $ yield Nothing
  yield $ Just x

-- | Group input values by the given predicate.
groupBy :: Monad m => (a -> a -> Bool) -> Pipe a [a] m r
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
filter :: Monad m => (a -> Bool) -> Pipe a a m r
filter p = forever $ takeWhile_ p

-- | Feed an input element to a pipe.
feed :: Monad m => a -> Pipe a b m r -> Pipe a b m r

-- this could be implemented as
-- feed x p = (yield x >> idP) >+> p
-- but this version is more efficient
feed _ (Pure r w) = Pure r w
feed _ (Throw e w) = Throw e w
feed a (Yield x b w) = Yield x (feed a b) w
feed a (M s m h) = M s (liftM (feed a) m) (feed a . h)
feed a (Await k _) = k a
