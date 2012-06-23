{-# LANGUAGE FlexibleInstances, TypeFamilies, KindSignatures #-}
{-# OPTIONS -fno-warn-orphans #-}

module Control.Pipe.Class (
  MonadStream(..),
  MonadStreamDefer(..),
  MonadStreamUnawait(..),

  ) where

import Control.Applicative
import Control.Monad
import Control.Monad.IO.Class
import Control.Pipe.Internal

class Monad3 m where
  return3 :: r -> m a b u r
  bind3 :: m a b u r -> (r -> m a b u s) -> m a b u s

instance Monad3 m => Monad (m a b u) where
  return = return3
  (>>=) = bind3

class Monad3 m => MonadStream m where
  type BaseMonad m :: * -> *

  -- | Wait for input from upstream within the 'Pipe' monad.
  --
  -- 'awaitE' blocks until input is ready.
  awaitE :: m a b u (Either u a)

  -- | Pass output downstream within the 'Pipe' monad.
  --
  -- 'yield' blocks until the downstream pipe calls 'await' again.
  yield :: b -> m a b u ()

  liftPipe :: Pipe (BaseMonad m) a b u r -> m a b u r

class MonadStream m => MonadStreamDefer m where
  defer :: u -> m a b u r

  await :: MonadStreamDefer m => m a b u a
  await = awaitE >>= either defer return

class MonadStream m => MonadStreamUnawait m where
  unawait :: a -> m a b u ()

instance Monad m => MonadStream (Pipe m) where
  type BaseMonad (Pipe m) = m
  awaitE = Await (return . Right) (return . Left) (\e -> Throw e awaitE [])
  yield x = Yield x (return ()) []
  liftPipe = id

instance Monad m => Monad3 (Pipe m) where
  return3 r = Pure r []
  Pure r w `bind3` f = case f r of
    Pure r' w' -> Pure r' (w ++ w')
    p'         -> foldr run p' w
      where
        run m p = M Masked (m >> return p) throwP
  Await k j h `bind3` f = Await (\x -> k x `bind3` f)
                                (\u -> j u `bind3` f)
                                (\e -> h e `bind3` f)
  M s m h `bind3` f = M s (m >>= \p -> return $ p `bind3` f)
                          (\e -> h e `bind3` f)
  Yield x p w `bind3` f = Yield x (p `bind3` f) w
  Throw e p w `bind3` f = Throw e (p `bind3` f) w

instance Monad m => Functor (Pipe m a b u) where
  fmap = liftM

instance Monad m => Applicative (Pipe m a b u) where
  pure = return
  (<*>) = ap

instance MonadIO m => MonadIO (Pipe m a b u) where
  liftIO = execP Unmasked . liftIO
