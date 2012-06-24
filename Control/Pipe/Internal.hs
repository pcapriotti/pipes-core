{-# LANGUAGE DeriveDataTypeable, FlexibleInstances #-}
module Control.Pipe.Internal (
  -- ** Low level types
  MaskState(..),
  Finalizer,
  Pipe(..),

  -- ** Low level primitives
  pureP,
  execP,
  throwP,
  catchP,
  finallyP,
  protectP,
  composeP,
  ) where

import Control.Exception hiding (Unmasked)
import Control.Monad

-- | Type of action in the base monad.
data MaskState
  = Masked     -- ^ Action to be run with asynchronous exceptions masked.
  | Unmasked   -- ^ Action to be run with asynchronous exceptions unmasked.

type Finalizer m = [m ()]

-- | The base type for pipes.
--
--  [@a@] The type of input received fom upstream pipes.
--
--  [@b@] The type of output delivered to downstream pipes.
--
--  [@m@] The base monad.
--
--  [@u@] THe upstream return type.
--
--  [@r@] The type of the monad's final result.
data Pipe m a b u r
  = Pure r (Finalizer m)
  | Await (a -> Pipe m a b u r)
          (u -> Pipe m a b u r)
          (SomeException -> Pipe m a b u r)
          (Finalizer m)
  | M MaskState (m (Pipe m a b u r))
                (SomeException -> Pipe m a b u r)
  | Yield b (Pipe m a b u r) (Finalizer m)
  | Throw SomeException (Pipe m a b u r) (Finalizer m)

pureP :: r -> Pipe m a b u r
pureP r = Pure r []

-- | Execute an action in the base monad with the given 'MaskState'.
execP :: Monad m => MaskState -> m r -> Pipe m a b u r
execP s m = M s (liftM pureP m) throwP

-- | Throw an exception within the 'Pipe' monad.
throwP :: Monad m => SomeException -> Pipe m a b u r
throwP e = p
  where p = Throw e p []

-- | Catch an exception within the pipe monad.
catchP :: Monad m
       => Pipe m a b u r
       -> (SomeException -> Pipe m a b u r)
       -> Pipe m a b u r
catchP (Pure r w) _ = Pure r w
catchP (Throw e _ w) h = protectP w (h e)
catchP (Await k j h w) h' = Await (\a -> catchP (k a) h')
                                  (\u -> catchP (j u) h')
                                  (\e -> catchP (h e) h') w
catchP (M s m h) h' = M s (m >>= \p' -> return $ catchP p' h')
                          (\e -> catchP (h e) h')
catchP (Yield x p w) h' = Yield x (catchP p h') w

-- | Add a finalizer to a pipe.
finallyP :: Monad m
         => Pipe m a b u r
         -> Finalizer m
         -> Pipe m a b u r
finallyP p w = go p
  where
    go (Pure r w') = Pure r (w ++ w')
    go (Throw e p' w') = Throw e (go p') (w ++ w')
    go (Yield x p' w') = Yield x (go p') (w ++ w')
    go (M s m h) = M s (liftM go m) (go . h)
    go (Await k j h w') = Await (go . k) (go . j) (go . h) (w ++ w')

protectP :: Monad m => Finalizer m -> Pipe m a b u r -> Pipe m a b u r
protectP w = go
  where
    go (Pure r w') = Pure r (w ++ w')
    go (Await k h j w') = Await k h j w'
    go (M s m h) = M s (liftM go m) (go . h)
    go (Yield x p' w') = Yield x (go p') (w ++ w')
    go (Throw e p' w') = Throw e (go p') (w ++ w')

composeP :: Monad m
         => Pipe m a b u r
         -> Pipe m b c r s
         -> Pipe m a c u s
composeP p1 p2 = case (p1, p2) of
  -- downstream step
  (_, Yield x p2' w) -> Yield x (composeP p1 p2') w
  (_, Throw e p2' w) -> Throw e (composeP p1 p2') w
  (_, M s m h2) -> M s (m >>= \p2' -> return $ composeP p1 p2')
                       (composeP p1 . h2)
  (_, Pure r w) -> Pure r w

  -- upstream step
  (M s m h1, Await { }) -> M s (m >>= \p1' -> return $ composeP p1' p2)
                               (\e -> composeP (h1 e) p2)
  (Await k j h w, Await { }) -> Await (\a -> composeP (k a) p2)
                                      (\u -> composeP (j u) p2)
                                      (\e -> composeP (h e) p2) w

  -- flow data
  (Yield x p1' w, Await k _ _ _) -> composeP p1' (protectP w (k x))
  (Pure r w, Await _ j _ _) -> composeP p1 (protectP w (j r))
  (Throw e p1' w, Await _ _ h _) -> composeP p1' (protectP w (h e))
