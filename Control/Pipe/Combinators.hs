{-# LANGUAGE ScopedTypeVariables #-}
-- | Basic pipe combinators.
module Control.Pipe.Combinators (
  -- ** Control operators
  tryAwait,
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
import Control.Pipe.Class
import Data.Maybe
import Prelude hiding (until, take, drop, concatMap, filter, takeWhile, dropWhile, catch)

-- | Like 'await', but returns @Just x@ when the upstream pipe yields some value
-- @x@, and 'Nothing' when it terminates.
--
-- Further calls to 'tryAwait' after upstream termination will keep returning
-- 'Nothing', whereas calling 'await' will terminate the current pipe
-- immediately.
tryAwait :: MonadStream m => m a b u (Maybe a)
tryAwait = awaitE >>= either (\_ -> return Nothing) (return . Just)

-- | Successively yield elements of a list.
fromList :: MonadStream m => [a] -> m x a u ()
fromList = mapM_ yield

-- | A pipe that terminates immediately.
nullP :: Monad3 m => m a b u ()
nullP = return ()

-- | A fold pipe. Apply a b uinary function to successive input values and an
-- accumulator, and return the final result.
fold :: MonadStream m => (b -> a -> b) -> b -> m a x u b
fold f = go
  where
    go x = awaitE >>= either (\_ -> return x) (let y = f x in y `seq` go . y)

-- | A variation of 'fold' without an initial value for the accumulator. This
-- pipe doesn't return any value if no input values are received.
fold1 :: MonadStreamDefer m => (a -> a -> a) -> m a x u a
fold1 f = await >>= fold f

-- | Accumulate all input values into a list.
consume :: MonadStream m => m a x u [a]
consume = fold (\xs x -> xs . (x:)) id <*> pure []

-- | Accumulate all input values into a non-empty list.
consume1 :: MonadStreamDefer m => m a x u [a]
consume1 = (:) <$> await <*> consume

-- | Act as an identity for the first 'n' values, then terminate.
take :: MonadStreamDefer m => Int -> m a a u ()
take n = replicateM_ n $ await >>= yield

-- | Remove the first 'n' values from the stream, then act as an identity.
drop :: MonadStream m => Int -> m a a r r
drop n = withDefer $ replicateM_ n await >> idP

-- | Apply a function with multiple return values to the stream.
pipeList :: MonadStream m => (a -> [b]) -> m a b r r
pipeList f = forP $ mapM_ yield . f

-- | Act as an identity until as long as inputs satisfy the given predicate.
-- Return the first element that doesn't satisfy the predicate.
takeWhile :: MonadStreamDefer m => (a -> Bool) -> m a a u a
takeWhile p = go
  where
    go = await >>= \x -> if p x then yield x >> go else return x

-- | Variation of 'takeWhile' returning @()@.
takeWhile_ :: MonadStreamDefer m => (a -> Bool) -> m a a u ()
takeWhile_ = void . takeWhile

-- | Remove inputs as long as they satisfy the given predicate, then act as an
-- identity.
dropWhile :: MonadStream m => (a -> Bool) -> m a a r r
dropWhile p = withDefer $ (takeWhile p >+> discard) >>= yield >> idP

-- | Group input values by the given predicate.
groupBy :: MonadStream m => (a -> a -> Bool) -> m a [a] r r
groupBy p = streaks >+> createGroups
  where
    streaks = withDefer $ do
      x <- await
      yield (Just x)
      r <- streaks' x
      yield Nothing
      return r

    streaks' x = withDefer $ do
      y <- await
      unless (p x y) $ yield Nothing
      yield $ Just y
      streaks' y

    createGroups = withDefer . forever $
      takeWhile isJust >+>
      pipe fromJust >+>
      (consume >>= yield)

-- | Remove values from the stream that don't satisfy the given predicate.
filter :: MonadStream m => (a -> Bool) -> m a a r r
filter p = withDefer . forever $ takeWhile p

-- | Feed an input element to a pipe.
feed :: MonadStream m => a -> Pipe (BaseMonad m) a b u r -> m a b u r
feed x p = withUnawait $ unawait x >> liftPipe p
