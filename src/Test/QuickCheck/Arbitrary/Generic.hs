{- |

Generic implementation of the 'arbitrary' method. Example usage:

@
data Foo = Foo
  { _fooX :: X
  , _fooY :: Y
  } deriving (Generic)

instance Arbitrary Foo where
  arbitrary = genericArbitrary
  shrink = genericShrink
@

This instance can also be derived using DerivingVia language extension

@
data Foo = Foo
  { _fooX :: X
  , _fooY :: Y
  } deriving (Generic)
    deriving (Arbitrary) via GenericArbitrary Foo
@

The generated 'arbitrary' method is equivalent to

@Foo <$> arbitrary <*> arbitrary@.

-}

module Test.QuickCheck.Arbitrary.Generic
  ( GenericArbitrary(..)
  , Arbitrary(..)
  , genericArbitrary
  , genericShrink
  ) where

import           Control.Applicative
import           Data.Coerce               (coerce)
import           Data.Proxy
import           Data.Type.Bool
import           GHC.Generics              as G
import           GHC.TypeLits
import           Test.QuickCheck           as QC
import           Test.QuickCheck.Arbitrary (GSubterms, RecursivelyShrink)
import           TypeFun.Data.Eq
import           TypeFun.Data.List

newtype GenericArbitrary a = GenericArbitrary { unGenericArbitrary :: a }
  deriving (Show, Eq)

instance
  ( Generic a,
    GArbitrary a (Rep a) 'True,
    RecursivelyShrink (Rep a),
    GSubterms (Rep a) a
  ) => Arbitrary (GenericArbitrary a) where
  arbitrary = coerce (genericArbitrary :: Gen a)
  shrink = coerce (genericShrink :: a -> [a])

type family AllFieldsFinal self (a :: * -> *) :: Bool where
  AllFieldsFinal self U1 = 'True
  AllFieldsFinal self (a :*: b) = AllFieldsFinal self a && AllFieldsFinal self b
  AllFieldsFinal self (M1 S t (K1 R self)) = 'False
  AllFieldsFinal self (M1 S t (K1 R other)) = 'True

type family Finite self (a :: * -> *) :: Bool where
  Finite self U1 = 'True
  -- | The constructor field is the ADT itself. Not finite.
  Finite self (K1 R self) = 'False
  Finite self (K1 R other) = 'True
  Finite self (a :*: b) = Finite self a && Finite self b
  Finite self (M1 D t f) = Finite self f
  Finite self (a :+: b) = Finite self a || Finite self b
  Finite self (M1 C c f) = AllFieldsFinal self f
  Finite self (M1 S s f) = Finite self f

-- | Calculates count of constructors encoded by particular ':+:'.
-- Internal use only.
type family SumLen a :: Nat where
  SumLen (a G.:+: b) = (SumLen a) + (SumLen b)
  SumLen a           = 1

-- | Generic arbitrary.
--
-- Parameters are:
-- * self: the ADT we generating instance for
-- * a: some part of the `Rep self`
-- * finite: Is `a` finite? Infinite type has no finite values (like Stream)
class (Finite self a ~ finite) => GArbitrary self a (finite :: Bool) where
  gArbitrary :: QC.Gen (a x)

instance
  ( GArbitrary self (C1 c f) 'True
  ) => GArbitrary self (D1 t (C1 c f)) 'True where
  gArbitrary = M1 <$> gArbitrary @self

-- | The constructor meta information
instance
  ( GArbitrary self f some
  , AllFieldsFinal self f ~ some
  ) => GArbitrary self (C1 c f) some where
  gArbitrary = M1 <$> scale predNat (gArbitrary @self)
    where
      predNat 0 = 0
      predNat n = pred n

-- | Unit type instance
instance GArbitrary self U1 'True where
  gArbitrary = pure U1

-- | Constructor field meta information
instance GArbitrary self f some => GArbitrary self (S1 t f) some where
  gArbitrary = M1 <$> gArbitrary @self

-- | Data of the constructor field
instance
  ( Arbitrary t
  , Finite self (Rec0 t) ~ some
  ) => GArbitrary self (Rec0 t) some where
  gArbitrary = K1 <$> arbitrary

-- | Product
instance
  ( GArbitrary self a af
  , GArbitrary self b bf
  , (af && bf) ~ some
  ) => GArbitrary self (a :*: b) some where
  gArbitrary = liftA2 (:*:) (gArbitrary @self) (gArbitrary @self)

instance
  ( TypeError (ShowType self :<>: Text " refers to itself in all constructors")
  , AllFieldsFinal self f ~ 'False
  ) => GArbitrary self (D1 t (C1 c f)) 'False where
  gArbitrary = error "Unreachable"

-- | ADT declaration with multiple constructors
instance
  ( FiniteSum self a b af bf
  , GArbitrary self (a :+: b) 'True
  ) => GArbitrary self (D1 t (a :+: b)) 'True where
  gArbitrary = sized $ \s -> M1 <$>
    if s > 1 then gArbitrary @self else oneof (finiteSum @self @a @b)

-- | Any sum inside of declaration
instance
  ( GArbitrary self a af, GArbitrary self b bf
  , KnownNat (SumLen a), KnownNat (SumLen b)
  , (af || bf) ~ some
  ) => GArbitrary self (a :+: b) some where
  gArbitrary = frequency
    [ (lfreq, G.L1 <$> gArbitrary @self)
    , (rfreq, G.R1 <$> gArbitrary @self) ]
    where
      lfreq = fromIntegral $ natVal (Proxy :: Proxy (SumLen a))
      rfreq = fromIntegral $ natVal (Proxy :: Proxy (SumLen b))

class
  ( Finite self a ~ af, Finite self b ~ bf
  ) => FiniteSum self (a :: * -> *) (b :: * -> *) af bf where
  finiteSum :: [Gen ((a :+: b) p)]

instance
  ( FiniteSumElem self a, FiniteSumElem self b
  , Finite self a ~ 'True
  , Finite self b ~ 'True
  ) => FiniteSum self a b 'True 'True where
  finiteSum = concat
    [ fmap L1 <$> finiteElem @self @a
    , fmap R1 <$> finiteElem @self @b]

instance
  ( FiniteSumElem self a
  , Finite self a ~ 'True
  , Finite self b ~ 'False
  ) => FiniteSum self a b 'True 'False where
  finiteSum = fmap L1 <$> finiteElem @self @a

instance
  ( FiniteSumElem self b
  , Finite self a ~ 'False
  , Finite self b ~ 'True
  ) => FiniteSum self a b 'False 'True where
  finiteSum = fmap R1 <$> finiteElem @self @b

class FiniteSumElem self a where
  finiteElem :: [Gen (a p)]

instance
  ( FiniteSum self a b af bf
  ) => FiniteSumElem self (a :+: b) where
  finiteElem = finiteSum @self

instance
  ( GArbitrary self (C1 c f) 'True
  ) => FiniteSumElem self (C1 c f) where
  finiteElem = [gArbitrary @self]

instance
  ( TypeError (ShowType self :<>: Text " refers to itself in all constructors")
  , (Finite self a || Finite self b) ~ 'False
  ) => GArbitrary self (D1 t (a :+: b)) 'False where
  gArbitrary = error "Unreachable"

genericArbitrary
  :: forall a ga some
  . (Generic a, GArbitrary a ga some, ga ~ Rep a)
  => Gen a
genericArbitrary = G.to <$> gArbitrary @a
