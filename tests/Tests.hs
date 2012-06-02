{-# OPTIONS -fno-warn-orphans #-}

import Control.Monad
import Control.Monad.Trans.Writer (tell, runWriter)
import Control.Monad.Trans.Class
import Control.Pipe
import Control.Pipe.Combinators (($$), tryAwait)
import Control.Pipe.Exception
import qualified Control.Pipe.Combinators as P
import Data.Functor.Identity
import Data.List
import Test.Framework
import Test.Framework.Providers.QuickCheck2

instance Show (a -> b) where
  show _ = "<function>"

id' :: Monad m => m r -> Pipe a a m r
id' m = tryAwait >>= maybe (lift m) (\x -> yield x >> id' m)

prop_fold :: (Int -> Int -> Int) -> Int -> [Int] -> Bool
prop_fold f z xs = foldl f z xs == run p
  where p = (mapM_ yield xs >> return 0) >+> P.fold f z

prop_id_finalizer :: String -> Int -> Bool
prop_id_finalizer s n = runWriter (runPurePipe_ p) == (s, [n])
  where
    p = return "" >+>
        id' (tell [n] >> return s)

prop_id :: Int -> Bool
prop_id n = run p == Just n
  where
    p = (yield n >> return Nothing) >+>
        id' (return Nothing) >+>
        liftM Just await

run :: Pipe () Void Identity r -> r
run = runIdentity . runPurePipe_

prop_consume :: [Int] -> Bool
prop_consume xs =
  run (P.fromList xs $$ P.consume) ==
  Just xs

prop_take :: Int -> [Int] -> Bool
prop_take n xs =
  run (P.fromList xs >+> P.take n $$ P.consume) ==
  Just (take n xs)

prop_take_head :: Int -> [Int] -> Bool
prop_take_head n xs =
  run (P.fromList xs >+> P.take (n + 1) $$ await) ==
  run (P.fromList xs $$ await)

prop_drop :: Int -> [Int] -> Bool
prop_drop n xs =
  run (P.fromList xs >+> P.drop n $$ P.consume)
  == Just (drop n xs)

prop_pipeList :: [Int] -> (Int -> [Int]) -> Bool
prop_pipeList xs f =
  run (P.fromList xs >+> P.pipeList f $$ P.consume) ==
  Just (concatMap f xs)

prop_takeWhile :: (Int -> Bool) -> [Int] -> Bool
prop_takeWhile p xs =
  run (P.fromList xs >+> P.takeWhile_ p $$ P.consume) ==
  Just (takeWhile p xs)

prop_dropWhile:: (Int -> Bool) -> [Int] -> Bool
prop_dropWhile p xs =
  run (P.fromList xs >+> P.dropWhile p $$ P.consume) ==
  Just (dropWhile p xs)

prop_groupBy :: [Int] -> Bool
prop_groupBy xs =
  run (P.fromList xs >+> P.groupBy (==) $$ P.consume) ==
  Just (groupBy (==) xs)

prop_filter :: [Int] -> (Int -> Bool) -> Bool
prop_filter xs p =
  run (P.fromList xs >+> P.filter p $$ P.consume) ==
  Just (filter p xs)

prop_finalizer_assoc :: [Int] -> Bool
prop_finalizer_assoc xs = runWriter (runPurePipe_ p) == runWriter (runPurePipe_ p')
  where
    p = (p1 >+> p2) >+> p3
    p' = p1 >+> (p2 >+> p3)
    p1 = finally (mapM_ yield xs) (tell [Just (1 :: Int)])
    p2 = void await
    p3 = tryAwait >>= lift . tell . return

prop_yield_failure :: Bool
prop_yield_failure = runWriter (runPurePipe_ p) == runWriter (runPurePipe_ p')
  where
    p = p1 >+> return ()
    p' = (p1 >+> idP) >+> return ()
    p1 = yield () >> lift (tell [1 :: Int])

prop_yield_failure_assoc :: Bool
prop_yield_failure_assoc = runWriter (runPurePipe_ p) == runWriter (runPurePipe_ p')
  where
    p = p1 >+> (idP >+> return ())
    p' = (p1 >+> idP) >+> return ()
    p1 = yield () >> lift (tell [1 :: Int])

prop_bup_leak :: Bool
prop_bup_leak = either (const False) (== ()) . runIdentity . runPurePipe $ p
  where
    p = yield () >+> void (await >> await)

prop_lift_assoc :: Bool
prop_lift_assoc = runWriter (runPurePipe_ p) == runWriter (runPurePipe_ p')
  where
    p = (lift (tell [1 :: Int]) >+> yield ()) >+> return ()
    p' = lift (tell [1 :: Int]) >+> (yield () >+> return ())

prop_loop_queue :: [Int] -> Bool
prop_loop_queue xs =
  run (loopP (mapM_ (yield . Right) xs >> replicateM (length xs) await)) == map Right xs

main :: IO ()
main = defaultMain [
  testGroup "properties"
    [ testProperty "fold" prop_fold
    , testProperty "id_finalizer" prop_id_finalizer
    , testProperty "identity" prop_id
    , testProperty "consume . fromList" prop_consume
    , testProperty "take . fromList" prop_take
    , testProperty "head . take == head" prop_take
    , testProperty "drop . fromList" prop_take
    , testProperty "pipeList == concatMap" prop_pipeList
    , testProperty "takeWhile" prop_takeWhile
    , testProperty "dropWhile" prop_dropWhile
    , testProperty "groupBy" prop_groupBy
    , testProperty "filter" prop_filter
    , testProperty "finalizer assoc" prop_finalizer_assoc
    , testProperty "yield failure" prop_yield_failure
    , testProperty "yield failure assoc" prop_yield_failure_assoc
    , testProperty "bup leak" prop_bup_leak
    , testProperty "lift assoc" prop_lift_assoc
    , testProperty "loop queue" prop_loop_queue
    ]
  ]
