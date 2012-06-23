{-# LANGUAGE DeriveDataTypeable #-}
module Control.Pipe.Internal (
  -- ** Low level types
  BrokenPipe(..),
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
  ) where

import Control.Exception hiding (Unmasked)
import Control.Monad
import Data.Typeable

-- | The 'BrokenPipe' exception is used to signal termination of the
-- upstream portion of a 'Pipeline' before the current pipe
--
-- A 'BrokenPipe' exception can be caught to perform cleanup actions
-- immediately before termination, like returning a result or yielding
-- additional values.
data BrokenPipe = BrokenPipe
  deriving (Show, Typeable)

instance Exception BrokenPipe


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
catchP (Await k j h) h' = Await (\a -> catchP (k a) h')
                                (\u -> catchP (j u) h')
                                (\e -> catchP (h e) h')
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
    go (Throw e p' w') = Throw e p' (w ++ w')
    go (Yield x p' w') = Yield x p' (w ++ w')
    go (M s m h) = M s (liftM go m) (go . h)
    go (Await k j h) = Await (go . k) (go . j) (go . h)

protectP :: Monad m => Finalizer m -> Pipe m a b u r -> Pipe m a b u r
protectP w = go
  where
    go (Pure r w') = Pure r (w ++ w')
    go (Await k h j) = Await k h j
    go (M s m h) = M s (liftM go m) (go . h)
    go (Yield x p' w') = Yield x (go p') (w ++ w')
    go (Throw e p' w') = Throw e (go p') (w ++ w')