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
  withUnawait,
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

  compose :: m a b u r -> Pipe (BaseMonad m) b c r s -> m a c u s

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
  awaitE = Await (return . Right) (return . Left) (\e -> Throw e awaitE []) []
  yield x = Yield x (return ()) []
  liftPipe = id
  compose = composeP

instance Monad m => Monad3 (Pipe m) where
  return3 r = Pure r []
  Pure r w `bind3` f = case f r of
    Pure r' w' -> Pure r' (w ++ w')
    p'         -> foldr run p' w
      where
        run m p = M Masked (m >> return p) throwP
  Await k j h w `bind3` f = Await (\x -> k x `bind3` f)
                                  (\u -> j u `bind3` f)
                                  (\e -> h e `bind3` f) w
  M s m h `bind3` f = M s (m >>= \p -> return $ p `bind3` f)
                          (\e -> h e `bind3` f)
  Yield x p w `bind3` f = Yield x (p `bind3` f) w
  Throw e p w `bind3` f = Throw e (p `bind3` f) w

instance Monad3 m => Functor (m a b u) where
  fmap = liftM

instance Monad3 m => Applicative (m a b u) where
  pure = return
  (<*>) = ap

instance (MonadStream m, MonadIO (BaseMonad m)) => MonadIO (m a b u) where
  liftIO = liftPipe . execP Unmasked . liftIO

-- PipeD

newtype PipeD m a b u r = PipeD
  { unPipeD :: EitherT u (Pipe m a b u) r }

instance Monad m => Monad3 (PipeD m) where
  return3 r = PipeD $ return r
  bind3 (PipeD m) f = PipeD $ m >>= unPipeD . f

handleDefers :: Monad m => Pipe m a b u r -> Pipe m a b (Either x u) (Either x r)
handleDefers = go
  where
    go (Pure r w) = Pure (Right r) w
    go (Throw e p w) = Throw e (go p) w
    go (Await k j h w) = Await (go . k) j' (go . h) w
      where j' (Left x) = Pure (Left x) w
            j' (Right x) = go $ j x
    go (Yield b p w) = Yield b (go p) w
    go (M s m h) = M s (liftM go m) (go . h)

instance Monad m => MonadStream (PipeD m) where
  type BaseMonad (PipeD m) = m

  awaitE = liftPipe awaitE
  yield = liftPipe . yield
  liftPipe = PipeD . lift
  compose (PipeD p1) p2 = PipeD . EitherT $
    compose (runEitherT p1) (handleDefers p2)

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

handleUnawaits :: Monad m => x -> Pipe m a b u r -> Pipe m a b (u, x) (r, x)
handleUnawaits = go
  where
    go x (Pure r w) = Pure (r, x) w
    go x (Throw e p w) = Throw e (go x p) w
    go x (Await k j h w) = Await (go x . k) j' (go x . h) w
      where j' (u, x') = go x' (j u)
    go x (Yield b p w) = Yield b (go x p) w
    go x (M s m h) = M s (liftM (go x) m) (go x . h)

liftPipeL :: Monad m => Pipe m a b u r -> StateT [a] (Pipe m a b u) r
liftPipeL (Pure r w) = lift (Pure r w)
liftPipeL (Throw e p w) = do
  lift $ Throw e (return ()) w
  liftPipeL p
liftPipeL (Yield x p w) = do
  lift $ Yield x (return ()) w
  liftPipeL p
liftPipeL (Await k j h w) = get >>= \xs -> case xs of
  [] -> do
    x <- lift $ Await (return . Right . Right)
                      (return . Right . Left)
                      (return . Left) w
    case x of
      Right (Right a) -> liftPipeL (k a)
      Right (Left u) -> liftPipeL (j u)
      Left e -> liftPipeL (h e)
  (x:xs') -> put xs' >> liftPipeL (k x)
liftPipeL (M s m h) = do
  x <- lift $ M s (liftM (return . Right) m) (return . Left)
  case x of
    Left e -> liftPipeL (h e)
    Right p' -> liftPipeL p'

instance Monad m => MonadStream (PipeL m) where
  type BaseMonad (PipeL m) = m

  awaitE = liftPipe awaitE
  yield = liftPipe . yield

  liftPipe = PipeL . liftPipeL

  compose (PipeL p1) p2 = PipeL $ do
    let p1' = runStateT p1 []
    (r, xs) <- lift $ compose p1' (handleUnawaits [] p2)
    put xs
    return r

instance Monad m => MonadStreamUnawait (PipeL m) where
  unawait = PipeL . modify . (:)

  runUnawait = (`evalStateT` []) . unPipeL

withUnawait :: MonadStream m => PipeL (BaseMonad m) a b u r -> m a b u r
withUnawait = liftPipe . runUnawait
