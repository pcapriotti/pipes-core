module Control.Pipe.Monoidal (
  -- | The combinators in this module allow you to create and manipulate
  -- multi-channel pipes. Multiple input or output channels are represented with
  -- 'Either' types.
  --
  -- Most of the combinators are generalizations of the corresponding functions
  -- in 'Control.Arrow', and obey appropriately generalized laws.
  firstP,
  firstResultP,
  secondP,
  secondResultP,
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

-- | Create a 'Pipe' that behaves like the given 'Pipe' of the left component
-- of the input, and lets values in the right component pass through.
firstP :: Monad m
       => Pipe m a b u r
       -> Pipe m (Either a c) (Either b c) u r
firstP (Pure r w) = Pure r w
firstP (Yield x p w) = Yield (Left x) (firstP p) w
firstP (Throw e p w) = Throw e (firstP p) w
firstP (M s m h) = M s (liftM firstP m) (firstP . h)
firstP (Await k j h w) = go
  where
    go = Await (either (firstP . k)
                       (yield . Right >=> const go))
               (firstP . j)
               (firstP . h) w

firstResultP :: Monad m
             => Pipe m a b u r
             -> Pipe m a b (Either u x) (Either r x)
firstResultP (Pure r w) = Pure (Left r) w
firstResultP (Throw e p w) = Throw e (firstResultP p) w
firstResultP (Yield x p w) = Yield x (firstResultP p) w
firstResultP (M s m h) = M s (liftM firstResultP m) (firstResultP . h)
firstResultP (Await k j h w) = go
  where
    go = Await (firstResultP . k)
               (either (firstResultP . j)
                       (return . Right))
               (firstResultP . h) w

-- | This function is the equivalent of 'firstP' for the right component.
secondP :: Monad m
        => Pipe m a b u r
        -> Pipe m (Either c a) (Either c b) u r
secondP (Pure r w) = Pure r w
secondP (Yield x p w) = Yield (Right x) (secondP p) w
secondP (Throw e p w) = Throw e (secondP p) w
secondP (M s m h) = M s (liftM secondP m) (secondP . h)
secondP (Await k j h w) = go
  where
    go = Await (either (yield . Left >=> const go)
                       (secondP . k))
               (secondP . j)
               (secondP . h) w

secondResultP :: Monad m
              => Pipe m a b u r
              -> Pipe m a b (Either x u) (Either x r)
secondResultP (Pure r w) = Pure (Right r) w
secondResultP (Throw e p w) = Throw e (secondResultP p) w
secondResultP (Yield x p w) = Yield x (secondResultP p) w
secondResultP (M s m h) = M s (liftM secondResultP m) (secondResultP . h)
secondResultP (Await k j h w) = go
  where
    go = Await (secondResultP . k)
               (either (return . Left)
                       (secondResultP . j))
               (secondResultP . h) w

-- | Combine two pipes into a single pipe that behaves like the first on the
-- left component, and the second on the right component.
(***) :: Monad m
      => Pipe m a b u r
      -> Pipe m a' b' r s
      -> Pipe m (Either a a') (Either b b') u s
p1 *** p2 = firstP p1 >+> secondP p2

-- | Convert between the two possible associations of a triple sum.
associateP :: Monad m
           => Pipe m (Either (Either a b) c) (Either a (Either b c)) r r
associateP = pipe associate

-- | Inverse of 'associateP'.
disassociateP :: Monad m
              => Pipe m (Either a (Either b c)) (Either (Either a b) c) r r
disassociateP = pipe disassociate

-- | Discard all values on the left component.
discardL :: Monad m => Pipe m (Either x a) a r r
discardL = firstP discard >+> pipe idl

-- | Discard all values on the right component.
discardR :: Monad m => Pipe m (Either a x) a r r
discardR = secondP discard >+> pipe idr

-- | Swap the left and right components.
swapP :: Monad m => Pipe m (Either a b) (Either b a) r r
swapP = pipe swap

-- | Yield all input values into both the left and right components of the
-- output.
splitP :: Monad m => Pipe m a (Either a a) r r
splitP = forP yield2
  where
    yield2 x = yield (Left x) >> yield (Right x)

-- | Yield both components of input values into the output.
joinP :: Monad m => Pipe m (Either a a) a r r
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
loopP :: Monad m => Pipe m (Either a c) (Either b c) u r -> Pipe m a b u r
loopP = go emptyQueue
  where
    go :: Monad m => Queue c -> Pipe m (Either a c) (Either b c) u r -> Pipe m a b u r
    go _ (Pure r w) = Pure r w
    go q (Yield (Right x) p _) = go (enqueue x q) p
    go q (Throw e p w) = Throw e (go q p) w
    go q (Yield (Left x) p w) = Yield x (go q p) w
    go q (M s m h) = M s (liftM (go q) m) (go q . h)
    go q (Await k j h w) = case dequeue q of
      (q', Nothing) -> Await (go q' . k . Left) (go q' . j) (go q' . h) w
      (q', Just x) -> go q' $ k (Right x)
