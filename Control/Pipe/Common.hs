{-# LANGUAGE FlexibleContexts, Rank2Types, ScopedTypeVariables #-}
module Control.Pipe.Common (
  -- ** Types
  Pipe,
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
  -- > check :: Pipe a a r IO r
  -- > check = forever $ do
  -- >   x <- await
  -- >   lift $ putStrLn $ "Can " ++ show x ++ " pass?"
  -- >   ok <- lift $ read <$> getLine
  -- >   when ok $ yield x
  awaitE,
  yield,
  exec,
  masked,

  -- ** Basic combinators
  pipe,
  forP,
  idP,
  discard,
  (>+>),
  (<+<),

  -- ** Running pipes
  runPipe,
  runPurePipe,
  runPurePipe_,
  ) where

import Control.Category
import Control.Exception (SomeException)
import qualified Control.Exception.Lifted as E
import Control.Pipe.Internal
import Control.Monad
import Control.Monad.Trans.Control
import Data.Void
import Prelude hiding (id, (.), catch)

-- | A pipe that can only produce values.
type Producer m b u = Pipe m () b u

-- | A pipe that can only consume values.
type Consumer m a u = Pipe m a Void u

-- | A self-contained pipeline that is ready to be run.
type Pipeline m u = Pipe m () Void u

-- | Wait for input from upstream within the 'Pipe' monad.
--
-- 'await' blocks until input is ready.
awaitE :: Monad m => Pipe m a b u (Either u a)
awaitE = Await (return . Right) (return . Left) (\e -> Throw e awaitE [])

-- | Pass output downstream within the 'Pipe' monad.
--
-- 'yield' blocks until the downstream pipe calls 'await' again.
yield :: Monad m => b -> Pipe m a b u ()
yield x = Yield x (return ()) []

-- | Execute an action in the base monad.
exec :: Monad m => m r -> Pipe m a b u r
exec = execP Unmasked

-- | Execute an action in the base monad with asynchronous exceptions masked.
--
-- This function is effective only if the 'Pipeline' is run with 'runPipe',
-- otherwise it is identical to 'exec'
masked :: Monad m => m r -> Pipe m a b u r
masked = execP Masked

-- | Execute the specified pipe for each value in the input stream.
--
-- Any action after a call to 'forP' will be executed when upstream terminates.
forP :: Monad m => (a -> Pipe m a b r s) -> Pipe m a b r r
forP f = awaitE >>= either return (\x -> f x >> forP f)

-- | Convert a pure function into a pipe.
--
-- > pipe = forever $ do
-- >   x <- await
-- >   yield (f x)
pipe :: Monad m => (a -> b) -> Pipe m a b r r
pipe f = forP $ yield . f

-- | The identity pipe.
idP :: Monad m => Pipe m a a r r
idP = pipe id

-- | The 'discard' pipe silently discards all input fed to it.
discard :: Monad m => Pipe m a b r r
discard = forP . const $ return ()

infixl 9 >+>
-- | Left to right pipe composition.
(>+>) :: Monad m => Pipe m a b u r -> Pipe m b c r s -> Pipe m a c u s
p1 >+> p2 = case (p1, p2) of
  -- downstream step
  (_, Yield x p2' w) -> Yield x (p1 >+> p2') w
  (_, Throw e p2' w) -> Throw e (p1 >+> p2') w
  (_, M s m h2) -> M s (m >>= \p2' -> return $ p1 >+> p2')
                       (\e -> p1 >+> h2 e)
  (_, Pure r w) -> Pure r w

  -- upstream step
  (M s m h1, Await { }) -> M s (m >>= \p1' -> return $ p1' >+> p2)
                               (\e -> h1 e >+> p2)
  (Await k j h, Await { }) -> Await (\a -> k a >+> p2)
                                    (\u -> j u >+> p2)
                                    (\e -> h e >+> p2)

  -- flow data
  (Yield x p1' w, Await k _ _) -> p1' >+> protectP w (k x)
  (Pure r w, Await _ j _) -> p1 >+> protectP w (j r)
  (Throw e p1' w, Await _ _ h) -> p1' >+> protectP w (h e)

infixr 9 <+<
-- | Right to left pipe composition.
(<+<) :: Monad m => Pipe m b c r s -> Pipe m a b u r -> Pipe m a c u s
p2 <+< p1 = p1 >+> p2

-- | Run a self-contained 'Pipeline', converting it to an action in the base
-- monad.
--
-- This function is exception-safe. Any exception thrown in the base monad
-- during execution of the pipeline will be captured by
-- 'Control.Pipe.Exception.catch' statements in the 'Pipe' monad.
runPipe :: MonadBaseControl IO m => Pipeline m u r -> m r
runPipe p = E.mask $ \restore -> run restore p
  where
    fin = mapM_ $ \m -> E.catch m (\(_ :: SomeException) -> return ())
    run restore = go
      where
        go (Pure r w) = fin w >> return r
        go (Await k _ _) = go (k ())
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
runPurePipe :: Monad m => Pipeline m u r -> m (Either SomeException r)
runPurePipe (Pure r w) = sequence_ w >> return (Right r)
runPurePipe (Await k _ _) = runPurePipe $ k ()
runPurePipe (Yield x _ _) = absurd x
runPurePipe (Throw e _ w) = sequence_ w >> return (Left e)
runPurePipe (M _ m _) = m >>= runPurePipe

-- | A version of 'runPurePipe' which rethrows any captured exception instead
-- of returning it.
runPurePipe_ :: Monad m => Pipeline m u r -> m r
runPurePipe_ = runPurePipe >=> either E.throw return
