{-# LANGUAGE DeriveDataTypeable #-}
module Control.Pipe.Internal (
  -- ** Low level types
  BrokenPipe(..),
  MaskState(..),
  Finalizer,
  Pipe(..),

  -- ** Low level primitives
  liftP,
  throwP,
  catchP,
  finallyP,
  protectP,
  ) where

import Control.Applicative
import Control.Exception hiding (Unmasked)
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Trans.Class
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
--  [@r@] The type of the monad's final result.
data Pipe l a b m r
  = Pure r (Finalizer m)
  | Await (a -> Pipe l a b m r)
          (SomeException -> Pipe l a b m r)
  | Unawait l (Pipe l a b m r)
  | Flush (Pipe l a b m r)
  | M MaskState (m (Pipe l a b m r))
                (SomeException -> Pipe l a b m r)
  | Yield b (Pipe l a b m r) (Finalizer m)
  | Throw SomeException (Pipe l a b m r) (Finalizer m)

instance Monad m => Monad (Pipe l a b m) where
  return r = Pure r []
  Pure r w >>= f = addFinalizer w (f r)
  Await k h >>= f = Await (k >=> f) (h >=> f)
  Unawait x p >>= f = Unawait x (p >>= f)
  Flush p >>= f = Flush (p >>= f)
  M s m h >>= f = M s (m >>= \p -> return $ p >>= f) (h >=> f)
  Yield x p w >>= f = Yield x (p >>= f) w
  Throw e p w >>= f = Throw e (p >>= f) w

addFinalizer :: Monad m
             => Finalizer m
             -> Pipe l a b m r
             -> Pipe l a b m r
addFinalizer w (Pure r w') = Pure r (w ++ w')
addFinalizer w p = foldr go p w
  where
    go m p' = M Masked (m >> return p') throwP

instance Monad m => Functor (Pipe l a b m) where
  fmap = liftM

instance Monad m => Applicative (Pipe l a b m) where
  pure = return
  (<*>) = ap

instance MonadTrans (Pipe l a b) where
  lift = liftP Unmasked

instance MonadIO m => MonadIO (Pipe l a b m) where
  liftIO = lift . liftIO

-- | Execute an action in the base monad with the given 'MaskState'.
liftP :: Monad m => MaskState -> m r -> Pipe l a b m r
liftP s m = M s (liftM return m) throwP

-- | Throw an exception within the 'Pipe' monad.
throwP :: Monad m => SomeException -> Pipe l a b m r
throwP e = p
  where p = Throw e p []

-- | Catch an exception within the pipe monad.
catchP :: Monad m
       => Pipe l a b m r
       -> (SomeException -> Pipe l a b m r)
       -> Pipe l a b m r
catchP (Pure r w) _ = Pure r w
catchP (Throw e _ w) h = protectP w (h e)
catchP (Await k h) h' = Await (\a -> catchP (k a) h')
                              (\e -> catchP (h e) h')
catchP (Unawait x p) h = Unawait x (catchP p h)
catchP (Flush p) h = Flush (catchP p h)
catchP (M s m h) h' = M s (m >>= \p' -> return $ catchP p' h')
                          (\e -> catchP (h e) h')
catchP (Yield x p w) h' = Yield x (catchP p h') w

-- | Add a finalizer to a pipe.
finallyP :: Monad m
         => Pipe l a b m r
         -> Finalizer m
         -> Pipe l a b m r
finallyP p w = go p
  where
    go (Pure r w') = Pure r (w ++ w')
    go (Throw e p' w') = Throw e p' (w ++ w')
    go (Yield x p' w') = Yield x p' (w ++ w')
    go (M s m h) = M s (liftM go m) (go . h)
    go (Await k h) = Await (go . k) (go . h)
    go (Unawait x p') = Unawait x (go p')
    go (Flush p') = Flush (go p')

protectP :: Monad m => Finalizer m -> Pipe l a b m r -> Pipe l a b m r
protectP w = go
  where
    go (Pure r w') = Pure r (w ++ w')
    go (Await k h) = Await k h
    go (Unawait x p) = Unawait x (go p)
    go (M s m h) = M s (liftM go m) (go . h)
    go (Yield x p' w') = Yield x (go p') (w ++ w')
    go (Throw e p' w') = Throw e (go p') (w ++ w')
    go (Flush p') = addFinalizer w p'
