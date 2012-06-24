{-# LANGUAGE MultiParamTypeClasses, TypeFamilies, FlexibleInstances #-}
{-# OPTIONS -fno-warn-orphans #-}

module Control.Pipe.Category (
  -- | This module contains category-theoretic instances corresponding to basic
  -- pipe combinators in 'Control.Pipe.Common' and 'Control.Pipe.Monoidal'.
  PipeC(..),
  IFunctor(..),
  ) where

import Control.Categorical.Bifunctor
import Control.Category
import Control.Category.Associative
import Control.Category.Braided
import Control.Category.Monoidal
import Control.Category.Multiplicative
import Control.Monad
import Control.Pipe.Common
import Control.Pipe.Monoidal
import Data.Void
import Prelude hiding ((.), id)

-- | Category of pipes.
--
-- Composition corresponds to '<+<' and identity to 'idP'.
newtype PipeC m r a b = PipeC { unPipeC :: Pipe m a b r r }

instance Monad m => Category (PipeC m r) where
  id = PipeC idP
  PipeC p2 . PipeC p1 = PipeC (p2 <+< p1)

instance Monad m => Category (Pipe m a a) where
  id = idP
  (.) = (<+<)

-- | Identity-on-objects functor.
--
-- This is part of the interface of Arrow.
class Category k => IFunctor k where
  arr :: (a -> b) -> k a b

instance Monad m => IFunctor (PipeC m r) where
  arr = PipeC . pipe

instance Monad m => IFunctor (Pipe m a a) where
  arr f = fmap f id

instance Monad m => PFunctor Either (PipeC m r) (PipeC m r) where
  first = PipeC . firstP . unPipeC where

instance Monad m => PFunctor Either (Pipe m a a) (Pipe m a a) where
  first = firstResultP

instance Monad m => QFunctor Either (PipeC m r) (PipeC m r) where
  second = PipeC . secondP . unPipeC where

instance Monad m => QFunctor Either (Pipe m a a) (Pipe m a a) where
  second = secondResultP

instance Monad m => Bifunctor Either (PipeC m r) (PipeC m r) (PipeC m r) where
  bimap f g = first f >>> second g

instance Monad m => Bifunctor Either (Pipe m a a) (Pipe m a a) (Pipe m a a) where
  bimap f g = first f >>> second g

instance Monad m => Associative (PipeC m r) Either where
  associate = PipeC associateP
  disassociate = PipeC disassociateP

instance Monad m => Associative (Pipe m a a) Either where
  associate = arr associate
  disassociate = arr disassociate

instance Monad m => Monoidal (PipeC m r) Either where
  type Id (PipeC m r) Either = Void

  idl = arr idl
  idr = arr idr
  coidl = arr coidl
  coidr = arr coidr

instance Monad m => Monoidal (Pipe m a a) Either where
  type Id (Pipe m a a) Either = Void

  idl = arr idl
  idr = arr idr
  coidl = arr coidl
  coidr = arr coidr

instance Monad m => Braided (PipeC m r) Either where
  braid = arr braid

instance Monad m => Braided (Pipe m a a) Either where
  braid = arr braid

instance Monad m => Symmetric (PipeC m r) Either where

instance Monad m => Symmetric (Pipe m a a) Either where

instance Monad m => Comultiplicative (PipeC m r) Either where
  counit = PipeC discard
  comult = PipeC splitP

instance Monad m => Multiplicative (PipeC m r) Either where
  unit = arr absurd
  mult = PipeC joinP

instance Monad m => Multiplicative (Pipe m a a) Either where
  unit = arr absurd
  mult = arr $ either id id
