{-# LANGUAGE TemplateHaskell #-}
{-# OPTIONS -fno-warn-orphans #-}

import Control.Monad
import Control.Monad.Trans.Writer (tell, runWriter)
import Control.Pipe
import Control.Pipe.Class
import Control.Pipe.Combinators (tryAwait)
import Control.Pipe.Exception
import qualified Control.Pipe.Combinators as P
import Data.Functor.Identity
import Data.List

import Test.Framework.Providers.QuickCheck2
import Test.Framework.TH.Prime

import Test.QuickCheck

instance Show (a -> b) where
  show _ = "<function>"

prop_fold :: (Int -> Int -> Int) -> Int -> [Int] -> Bool
prop_fold f z xs = foldl f z xs == run p
  where p = mapM_ yield xs >+> P.fold f z

prop_id_finalizer :: String -> Int -> Bool
prop_id_finalizer s n = runWriter (runPurePipe_ p) == (s, [n])
  where
    p = return "" >+>
        (idP >> exec (tell [n]) >> return s)

prop_id :: Int -> Bool
prop_id n = run p == n
  where
    p = (yield n >> return 0) >+>
        idP >+>
        withDefer await

run :: Pipeline Identity u r -> r
run = runIdentity . runPurePipe_

prop_consume :: [Int] -> Bool
prop_consume xs =
  run (P.fromList xs >+> P.consume) == xs

prop_take :: Int -> [Int] -> Bool
prop_take n xs =
  run (P.fromList xs >+> withDefer (P.take n) >+> P.consume) == take n xs

prop_take_head :: Positive Int -> [Int] -> Bool
prop_take_head (Positive n) xs =
  run (P.fromList xs >+> withDefer (P.take n) >+> tryAwait) ==
  run (P.fromList xs >+> tryAwait)

prop_drop :: Int -> [Int] -> Bool
prop_drop n xs =
  run (P.fromList xs >+> withDefer (P.drop n) >+> P.consume) == drop n xs

prop_pipeList :: [Int] -> (Int -> [Int]) -> Bool
prop_pipeList xs f =
  run (P.fromList xs >+> P.pipeList f >+> P.consume) == concatMap f xs

prop_takeWhile :: (Int -> Bool) -> [Int] -> Bool
prop_takeWhile p xs =
  run (P.fromList xs >+> withDefer (P.takeWhile_ p) >+> P.consume) == takeWhile p xs

prop_dropWhile:: (Int -> Bool) -> [Int] -> Bool
prop_dropWhile p xs =
  run (P.fromList xs >+> P.dropWhile p >+> P.consume) ==
  dropWhile p xs

prop_groupBy :: [Int] -> Bool
prop_groupBy xs =
  run (P.fromList xs >+> P.groupBy (==) >+> P.consume) == groupBy (==) xs

prop_filter :: [Int] -> (Int -> Bool) -> Bool
prop_filter xs p =
  run (P.fromList xs >+> P.filter p >+> P.consume) == filter p xs

prop_feed :: Int -> [Int] -> Bool
prop_feed x ys = run (P.fromList ys >+> P.feed x P.consume) == x:ys

prop_finalizer :: Int -> Int -> Int -> Bool
prop_finalizer x y z = runWriter (runPurePipe_ (p1 >+> p2)) == (True, [z, x, y])
  where
    p1 = finally (yield z >> return True) (tell [x])
    p2 = finally (forP (exec . tell . (:[]))) (tell [y])

prop_finalizer_assoc :: [Int] -> Bool
prop_finalizer_assoc xs = runWriter (runPurePipe_ p) == runWriter (runPurePipe_ p')
  where
    p = (p1 >+> p2) >+> p3
    p' = p1 >+> (p2 >+> p3)
    p1 = finally (mapM_ yield xs) (tell [Just (1 :: Int)])
    p2 = withDefer $ void await
    p3 = tryAwait >>= exec . tell . return

prop_yield_failure :: Bool
prop_yield_failure = runWriter (runPurePipe_ p) == runWriter (runPurePipe_ p')
  where
    p = p1 >+> return ()
    p' = (p1 >+> idP) >+> return ()
    p1 = yield () >> exec (tell [1 :: Int])

prop_yield_failure_assoc :: Bool
prop_yield_failure_assoc = runWriter (runPurePipe_ p) == runWriter (runPurePipe_ p')
  where
    p = p1 >+> (idP >+> return ())
    p' = (p1 >+> idP) >+> return ()
    p1 = yield () >> exec (tell [1 :: Int])

prop_bup_leak :: Bool
prop_bup_leak = either (const False) (== ()) . runIdentity . runPurePipe $ p
  where
    p = yield () >+> withDefer (await >> await)

prop_exec_assoc :: Bool
prop_exec_assoc = runWriter (runPurePipe_ p) == runWriter (runPurePipe_ p')
  where
    p = (exec (tell [1 :: Int]) >+> yield ()) >+> return ()
    p' = exec (tell [1 :: Int]) >+> (yield () >+> return ())

prop_loop_queue :: [Int] -> Bool
prop_loop_queue xs =
  run (loopP (withDefer (mapM_ (yield . Right) xs >> replicateM (length xs) await))) == map Right xs

main :: IO ()
main = $(defaultMainGenerator)
