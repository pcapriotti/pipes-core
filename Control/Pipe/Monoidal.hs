module Control.Pipe.Monoidal (
  -- | The combinators in this module allow you to create and manipulate
  -- multi-channel pipes. Multiple input or output channels are represented with
  -- 'Either' types.
  --
  -- Most of the combinators are generalizations of the corresponding functions
  -- in 'Control.Arrow', and obey appropriately generalized laws.
  firstP,
  secondP,
  (***),
  associateP,
  disassociateP,
  discardL,
  discardR,
  swapP,
  joinP,
  splitP,
  loopP,
  ) where

import Control.Category.Associative
import Control.Category.Braided
import Control.Category.Monoidal
import Control.Monad
import Control.Pipe.Common
import Control.Pipe.Internal
import Data.Void

-- | Create a 'Pipe' that behaves like the given 'Pipe' of the left component
-- of the input, and lets values in the right component pass through.
firstP :: Monad m
       => Pipe l a b m r
       -> Pipe l (Either a c) (Either b c) m r
firstP (Pure r w) = Pure r w
firstP (Yield x p w) = Yield (Left x) (firstP p) w
firstP (Throw e p w) = Throw e (firstP p) w
firstP (M s m h) = M s (liftM firstP m) (firstP . h)
firstP (Unawait x p) = Unawait x (firstP p)
firstP (Flush p) = Flush (firstP p)
firstP (Await k h) = go
  where
    go = Await (either (firstP . k)
                       (yield . Right >=> const go))
               (firstP . h)

-- | This function is the equivalent of 'firstP' for the right component.
secondP :: Monad m
        => Pipe l a b m r
        -> Pipe l (Either c a) (Either c b) m r
secondP (Pure r w) = Pure r w
secondP (Yield x p w) = Yield (Right x) (secondP p) w
secondP (Throw e p w) = Throw e (secondP p) w
secondP (M s m h) = M s (liftM secondP m) (secondP . h)
secondP (Unawait x p) = Unawait x (secondP p)
secondP (Flush p) = Flush (secondP p)
secondP (Await k h) = go
  where
    go = Await (either (yield . Left >=> const go)
                       (secondP . k))
               (secondP . h)

-- | Combine two pipes into a single pipe that behaves like the first on the
-- left component, and the second on the right component.
(***) :: Monad m
      => Pipe Void a b m r
      -> Pipe Void a' b' m r
      -> Pipe Void (Either a a') (Either b b') m r
p1 *** p2 = firstP p1 >+> secondP p2

-- | Convert between the two possible associations of a triple sum.
associateP :: Monad m
           => Pipe l (Either (Either a b) c) (Either a (Either b c)) m r
associateP = pipe associate

-- | Inverse of 'associateP'.
disassociateP :: Monad m
              => Pipe l (Either a (Either b c)) (Either (Either a b) c) m r
disassociateP = pipe disassociate

-- | Discard all values on the left component.
discardL :: Monad m => Pipe l (Either x a) a m r
discardL = firstP discard >+> pipe idl

-- | Discard all values on the right component.
discardR :: Monad m => Pipe l (Either a x) a m r
discardR = secondP discard >+> pipe idr

-- | Swap the left and right components.
swapP :: Monad m => Pipe l (Either a b) (Either b a) m r
swapP = pipe swap

-- | Yield all input values into both the left and right components of the
-- output.
splitP :: Monad m => Pipe l a (Either a a) m r
splitP = forever $ await >>= yield2
  where
    yield2 x = yield (Left x) >> yield (Right x)

-- | Yield both components of input values into the output.
joinP :: Monad m => Pipe l (Either a a) a m r
joinP = pipe $ either id id

data Queue a = Queue ![a] ![a]

emptyQueue :: Queue a
emptyQueue = Queue [] []

enqueue :: a -> Queue a -> Queue a
enqueue x (Queue xs ys) = Queue xs (x : ys)

dequeue :: Queue a -> (Queue a, Maybe a)
dequeue (Queue (x : xs) ys) = (Queue xs ys, Just x)
dequeue q@(Queue [] []) = (q, Nothing)
dequeue (Queue [] ys) = dequeue (Queue (reverse ys) [])

-- | The 'loopP' combinator allows to create 'Pipe's whose output value is fed
-- back to the 'Pipe' as input.
loopP :: Monad m => Pipe Void (Either a c) (Either b c) m r -> Pipe Void a b m r
loopP = go emptyQueue
  where
    go _ (Pure r w) = Pure r w
    go q (Yield (Right x) p _) = go (enqueue x q) p
    go _ (Unawait x _) = absurd x
    go q (Flush p) = Flush (go q p)
    go q (Throw e p w) = Throw e (go q p) w
    go q (Yield (Left x) p w) = Yield x (go q p) w
    go q (M s m h) = M s (liftM (go q) m) (go q . h)
    go q (Await k h) = case dequeue q of
      (q', Nothing) -> Await (go q' . k . Left) (go q' . h)
      (q', Just x) -> go q' $ k (Right x)
