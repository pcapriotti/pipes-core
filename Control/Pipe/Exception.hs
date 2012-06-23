module Control.Pipe.Exception (
  throw,
  catch,
  bracket,
  bracket_,
  bracketOnError,
  finally,
  onException,
  ) where

import qualified Control.Exception as E
import Control.Pipe.Common
import Control.Pipe.Internal
import Prelude hiding (catch)

-- | Catch an exception within the 'Pipe' monad.
--
-- This function takes a 'Pipe', runs it, and if an exception is raised it
-- executes the handler, passing it the value of the exception.  Otherwise, the
-- result is returned as normal.
--
-- For example, given a 'Pipe':
--
-- > reader :: Pipe () String IO ()
--
-- we can use 'catch' to resume after an exception. For example:
--
-- > safeReader :: Pipe () (Either SomeException String) IO ()
-- > safeReader = catch (reader >+> 'Pipe' Right) $ \e -> do
-- >   yield $ Left e
--
-- Note that only the initial monadic actions contained in a handler are
-- guaranteed to be executed.  Anything else is subject to the usual
-- termination rule of 'Pipe's: if a 'Pipe' at either side terminates, the
-- whole pipeline terminates.
catch :: (Monad m, E.Exception e)
      => Pipe m a b u r               -- ^ 'Pipe' to run
      -> (e -> Pipe m a b u r)        -- ^ handler function
      -> Pipe m a b u r
catch p h = catchP p $ \e -> case E.fromException e of
  Nothing -> throwP e
  Just e' -> h e'

-- | Throw an exception within the 'Pipe' monad.
--
-- An exception thrown with 'throw' can be caught by 'catch' with any base
-- monad.
--
-- If the exception is not caught in the 'Pipeline' at all, it will be rethrown
-- as a normal Haskell exception when using 'runPipe'.  Note that 'runPurePipe'
-- returns the exception in an 'Either' value, instead.
throw :: (Monad m, E.Exception e) => e -> Pipe m a b u r
throw = throwP . E.toException

-- | Like 'finally', but only performs the final action if there was an
-- exception raised by the 'Pipe'.
onException :: Monad m
            => Pipe m a b u r       -- ^ 'Pipe' to run first
            -> Pipe m a b u s       -- ^ 'Pipe' to run if an exception happens
            -> Pipe m a b u r
onException p w = catchP p $ \e -> w >> throw e

-- | A specialized variant of 'bracket' with just a computation to run
-- afterwards.
finally :: Monad m
        => Pipe m a b u r           -- ^ 'Pipe' to run first
        -> m s                    -- ^ finalizer action
        -> Pipe m a b u r
finally p w = do
  r <- onException p (masked w)
  masked w
  return r

-- | Allocate a resource within the base monad, run a 'Pipe', then ensure the
-- resource is released.
--
-- The typical example is reading from a file:
--
-- > bracket
-- >   (openFile "filename" ReadMode)
-- >   hClose
-- >   (\handle -> do
-- >       line <- lift $ hGetLine handle
-- >       yield line
-- >       ...)
bracket :: Monad m
        => m r                  -- ^ action to acquire resource
        -> (r -> m y)           -- ^ action to release resource
        -> (r -> Pipe m a b u x)  -- ^ 'Pipe' to run in between
        -> Pipe m a b u x
bracket open close run = do
  r <- masked open
  finally (run r) (close r)

-- | A variant of 'bracket' where the return value from the allocation action
-- is not required.
bracket_ :: Monad m
         => m r                 -- ^ action to run first
         -> m y                 -- ^ action to run last
         -> Pipe m a b u x        -- ^ 'Pipe' to run in between
         -> Pipe m a b u x
bracket_ open close run =
  bracket open (const close) (const run)

-- | Like 'bracket', but only performs the \"release\" action if there was an
-- exception raised by the 'Pipe'.
bracketOnError :: Monad m
               => m r                     -- ^ action to acquire resource
               -> (r -> m y)              -- ^ action to release resource
               -> (r -> Pipe m a b u x)     -- ^ 'Pipe' to run in between
               -> Pipe m a b u x
bracketOnError open close run = do
  r <- masked open
  onException (run r) (masked $ close r)
