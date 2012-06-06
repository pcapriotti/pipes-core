{-# LANGUAGE DeriveDataTypeable, FlexibleContexts, Rank2Types, ScopedTypeVariables #-}
module Control.Pipe.Common (
  -- ** Types
  Pipe(..),
  Producer,
  Consumer,
  Pipeline,
  Void,

  -- ** Primitives
  --
  -- | 'await' and 'yield' are the two basic primitives you need to create
  -- 'Pipe's. Because 'Pipe' is a monad, you can assemble them using ordinary
  -- @do@ notation. Since 'Pipe' is also a monad trnasformer, you can use
  -- 'lift' to invoke the base monad. For example:
  --
  -- > check :: Pipe a a IO r
  -- > check = forever $ do
  -- >   x <- await
  -- >   lift $ putStrLn $ "Can " ++ show x ++ " pass?"
  -- >   ok <- lift $ read <$> getLine
  -- >   when ok $ yield x
  await,
  yield,
  masked,

  -- ** Basic combinators
  pipe,
  idP,
  discard,
  (>+>),
  (<+<),

  -- ** Running pipes
  runPipe,
  runPurePipe,
  runPurePipe_,

  -- ** Low level types
  BrokenPipe,
  MaskState(..),

  -- ** Low level primitives
  --
  -- | These functions can be used to implement exception-handling combinators.
  -- For normal use, prefer the functions defined in 'Control.Pipe.Exception'.
  throwP,
  catchP,
  finallyP,
  liftP,
  ) where

import Control.Applicative
import Control.Category
import Control.Exception (SomeException, Exception)
import qualified Control.Exception.Lifted as E
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Trans.Class
import Control.Monad.Trans.Control
import Data.Maybe
import Data.Typeable
import Data.Void
import Prelude hiding (id, (.), catch)

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
data Pipe a b m r
  = Pure r (Finalizer m)
  | Await (a -> Pipe a b m r)
          (SomeException -> Pipe a b m r)
  | M MaskState (m (Pipe a b m r))
                (SomeException -> Pipe a b m r)
  | Yield b (Pipe a b m r) (Finalizer m)
  | Throw SomeException (Pipe a b m r) (Finalizer m)

-- | A pipe that can only produce values.
type Producer b m = Pipe () b m

-- | A pipe that can only consume values.
type Consumer a m = Pipe a Void m

-- | A self-contained pipeline that is ready to be run.
type Pipeline m = Pipe () Void m

instance Monad m => Monad (Pipe a b m) where
  return r = Pure r []
  Pure r w >>= f = case f r of
    Pure r' w' -> Pure r' (w ++ w')
    p'         -> foldr run p' w
      where
        run m p = M Masked (m >> return p) throwP
  Await k h >>= f = Await (k >=> f) (h >=> f)
  M s m h >>= f = M s (m >>= \p -> return $ p >>= f) (h >=> f)
  Yield x p w >>= f = Yield x (p >>= f) w
  Throw e p w >>= f = Throw e (p >>= f) w

instance Monad m => Functor (Pipe a b m) where
  fmap = liftM

instance Monad m => Applicative (Pipe a b m) where
  pure = return
  (<*>) = ap

-- | Throw an exception within the 'Pipe' monad.
throwP :: Monad m => SomeException -> Pipe a b m r
throwP e = p
  where p = Throw e p []

-- | Catch an exception within the pipe monad.
catchP :: Monad m
       => Pipe a b m r
       -> (SomeException -> Pipe a b m r)
       -> Pipe a b m r
catchP (Pure r w) _ = Pure r w
catchP (Throw e _ w) h = protect w (h e)
catchP (Await k h) h' = Await (\a -> catchP (k a) h')
                              (\e -> catchP (h e) h')
catchP (M s m h) h' = M s (m >>= \p' -> return $ catchP p' h')
                          (\e -> catchP (h e) h')
catchP (Yield x p w) h' = Yield x (catchP p h') w

-- | Add a finalizer to a pipe.
finallyP :: Monad m
         => Pipe a b m r
         -> Finalizer m
         -> Pipe a b m r
finallyP p w = go p
  where
    go (Pure r w') = Pure r (w ++ w')
    go (Throw e p' w') = Throw e p' (w ++ w')
    go (Yield x p' w') = Yield x p' (w ++ w')
    go (M s m h) = M s (liftM go m) (go . h)
    go (Await k h) = Await (go . k) (go . h)

-- | Wait for input from upstream within the 'Pipe' monad.
--
-- 'await' blocks until input is ready.
await :: Monad m => Pipe a b m a
await = Await return (\e -> Throw e await [])

-- | Pass output downstream within the 'Pipe' monad.
--
-- 'yield' blocks until the downstream pipe calls 'await' again.
yield :: Monad m => b -> Pipe a b m ()
yield x = Yield x (return ()) []

-- | Execute an action in the base monad with the given 'MaskState'.
liftP :: Monad m => MaskState -> m r -> Pipe a b m r
liftP s m = M s (liftM return m) throwP

instance MonadTrans (Pipe a b) where
  lift = liftP Unmasked

instance MonadIO m => MonadIO (Pipe a b m) where
  liftIO = lift . liftIO

-- | Execute an action in the base monad with asynchronous exceptions masked.
--
-- This function is effective only if the 'Pipeline' is run with 'runPipe',
-- otherwise it is identical to 'lift'
masked :: Monad m => m r -> Pipe a b m r
masked = liftP Masked

-- | Convert a pure function into a pipe.
--
-- > pipe = forever $ do
-- >   x <- await
-- >   yield (f x)
pipe :: Monad m => (a -> b) -> Pipe a b m r
pipe f = forever $ await >>= yield . f

-- | The identity pipe.
idP :: Monad m => Pipe a a m r
idP = pipe id

-- | The 'discard' pipe silently discards all input fed to it.
discard :: Monad m => Pipe a b m r
discard = forever await

protect :: Monad m => Finalizer m -> Pipe a b m r -> Pipe a b m r
protect w = go
  where
    go (Pure r w') = Pure r (w ++ w')
    go (Await k h) = Await k h
    go (M s m h) = M s (liftM go m) (go . h)
    go (Yield x p' w') = Yield x (go p') (w ++ w')
    go (Throw e p' w') = Throw e (go p') (w ++ w')

handleBP :: Monad m => r -> Pipe a b m r -> Pipe a b m r
handleBP r = go
  where
    go (Pure r' w) = Pure r' w
    go (Await k h) = Await k h
    go (M s m h) = M s (liftM go m) (go . h)
    go (Yield x p' w) = Yield x (go p') w
    go (Throw e p' w)
      | isBrokenPipe e = Pure r w
      | otherwise      = Throw e (go p') w

bp :: SomeException
bp = E.toException BrokenPipe

isBrokenPipe :: SomeException -> Bool
isBrokenPipe e = isJust (E.fromException e :: Maybe BrokenPipe)

infixl 9 >+>
-- | Left to right pipe composition.
(>+>) :: Monad m => Pipe a b m r -> Pipe b c m r -> Pipe a c m r
p1 >+> p2 = case (p1, p2) of
  -- downstream step
  (_, Yield x p2' w) -> Yield x (p1 >+> p2') w
  (_, Throw e p2' w) -> Throw e (p1 >+> p2') w
  (_, M s m h2) -> M s (m >>= \p2' -> return $ p1 >+> p2')
                       (\e -> p1 >+> h2 e)
  (_, Pure r w) -> Pure r w

  -- upstream step
  (M s m h1, Await _ _) -> M s (m >>= \p1' -> return $ p1' >+> p2)
                               (\e -> h1 e >+> p2)
  (Await k h1, Await _ _) -> Await (\a -> k a >+> p2)
                                   (\e -> h1 e >+> p2)
  (Pure r w, Await _ h2) -> p1 >+> handleBP r (protect w (h2 bp))

  -- flow data
  (Yield x p1' w, Await k _) -> p1' >+> protect w (k x)
  (Throw e p1' w, Await _ h) -> p1' >+> protect w (h e)

infixr 9 <+<
-- | Right to left pipe composition.
(<+<) :: Monad m => Pipe b c m r -> Pipe a b m r -> Pipe a c m r
p2 <+< p1 = p1 >+> p2

-- | Run a self-contained 'Pipeline', converting it to an action in the base
-- monad.
--
-- This function is exception-safe. Any exception thrown in the base monad
-- during execution of the pipeline will be captured by
-- 'Control.Pipe.Exception.catch' statements in the 'Pipe' monad.
runPipe :: MonadBaseControl IO m => Pipeline m r -> m r
runPipe p = E.mask $ \restore -> run restore p
  where
    fin = mapM_ $ \m -> E.catch m (\(_ :: SomeException) -> return ())
    run restore = go
      where
        go (Pure r w) = fin w >> return r
        go (Await k _) = go (k ())
        go (Yield x _ _) = absurd x
        go (Throw e _ w) = fin w >> E.throwIO e
        go (M s m h) = try s m >>= \r -> case r of
          Left e   -> go $ h e
          Right p' -> go p'

        try s m = E.try $ case s of
          Unmasked -> restore m
          _ -> m


-- | Run a self-contained pipeline over an arbitrary monad, with fewer
-- exception-safety guarantees than 'runPipe'.
--
-- Only pipe termination exceptions and exceptions thrown using
-- 'Control.Pipe.Exception.throw' will be catchable within the 'Pipe' monad.
-- Any other exception will terminate execution immediately and finalizers will
-- not be called.
--
-- Any captured exception will be returned in the left component of the result.
runPurePipe :: Monad m => Pipeline m r -> m (Either SomeException r)
runPurePipe (Pure r w) = sequence_ w >> return (Right r)
runPurePipe (Await k _) = runPurePipe $ k ()
runPurePipe (Yield x _ _) = absurd x
runPurePipe (Throw e _ w) = sequence_ w >> return (Left e)
runPurePipe (M _ m _) = m >>= runPurePipe

-- | A version of 'runPurePipe' which rethrows any captured exception instead
-- of returning it.
runPurePipe_ :: Monad m => Pipeline m r -> m r
runPurePipe_ = runPurePipe >=> either E.throw return
