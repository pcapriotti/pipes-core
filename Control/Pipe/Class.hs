{-# LANGUAGE FlexibleInstances, TypeFamilies, KindSignatures, FlexibleContexts #-}
{-# OPTIONS -fno-warn-orphans #-}

module Control.Pipe.Class (
  Monad3(..),
  MonadStream(..),
  MonadStreamDefer(..),
  MonadStreamUnawait(..),
  PipeD,
  withDefer,
  PipeL,
  ) where

import Control.Applicative
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Trans.Class
import Control.Monad.Trans.Either
import Control.Monad.Trans.State
import Control.Pipe.Internal

class Monad3 m where
  return3 :: r -> m a b u r
  bind3 :: m a b u r -> (r -> m a b u s) -> m a b u s

instance Monad3 m => Monad (m a b u) where
  return = return3
  (>>=) = bind3

class (Monad3 m, Monad (BaseMonad m)) => MonadStream m where
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

  runDefer :: m a b r r -> Pipe (BaseMonad m) a b r r

class MonadStream m => MonadStreamUnawait m where
  unawait :: a -> m a b u ()

  runUnawait :: m a b u r -> Pipe (BaseMonad m) a b u r

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

instance Monad3 m => Functor (m a b u) where
  fmap = liftM

instance Monad3 m => Applicative (m a b u) where
  pure = return
  (<*>) = ap

instance MonadIO m => MonadIO (Pipe m a b u) where
  liftIO = execP Unmasked . liftIO

-- PipeD

newtype PipeD m a b u r = PipeD
  { unPipeD :: EitherT u (Pipe m a b u) r }

instance Monad m => Monad3 (PipeD m) where
  return3 r = PipeD $ return r
  bind3 (PipeD m) f = PipeD $ m >>= unPipeD . f

instance Monad m => MonadStream (PipeD m) where
  type BaseMonad (PipeD m) = m

  awaitE = liftPipe awaitE
  yield = liftPipe . yield
  liftPipe = PipeD . lift

instance Monad m => MonadStreamDefer (PipeD m) where
  defer = PipeD . hoistEither . Left
  runDefer = liftM (either id id) . runEitherT . unPipeD

withDefer :: MonadStream m => PipeD (BaseMonad m) a b r r -> m a b r r
withDefer = liftPipe . runDefer

-- PipeL

newtype PipeL m a b u r = PipeL
  { unPipeL :: StateT [a] (Pipe m a b u) r }

instance Monad m => Monad3 (PipeL m) where
  return3 r = PipeL $ return r
  bind3 (PipeL m) f = PipeL $ m >>= unPipeL . f

instance Monad m => MonadStream (PipeL m) where
  type BaseMonad (PipeL m) = m

  awaitE = PipeL $ get >>= \stack -> case stack of
    [] -> lift awaitE
    (x : xs) -> put xs >> return (Right x)

  yield = liftPipe . yield
  liftPipe = PipeL . lift

instance Monad m => MonadStreamUnawait (PipeL m) where
  unawait = PipeL . modify . (:)

  runUnawait = (`evalStateT` []) . unPipeL
