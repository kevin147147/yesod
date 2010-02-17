{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE OverlappingInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE QuasiQuotes #-}
---------------------------------------------------------
--
-- Module        : Yesod.Resource
-- Copyright     : Michael Snoyman
-- License       : BSD3
--
-- Maintainer    : Michael Snoyman <michael@snoyman.com>
-- Stability     : Stable
-- Portability   : portable
--
-- Defines the ResourceName class.
--
---------------------------------------------------------
module Yesod.Resource
    ( mkResources
    , mkResourcesNoCheck
#if TEST
      -- * Testing
    , testSuite
#endif
    ) where

import Data.List.Split (splitOn)
import Yesod.Definitions
import Data.List (nub)
import Data.Char (isDigit)

import Language.Haskell.TH.Syntax
import Language.Haskell.TH.Quote
import Network.Wai (Method (..), methodFromBS, methodToBS)
{- Debugging
import Language.Haskell.TH.Ppr
import System.IO
-}

import Data.Typeable
import Control.Exception (Exception)
import Data.Attempt -- for failure stuff
import Data.Object.Text
import Control.Monad ((<=<), unless, zipWithM)
import Data.Object.Yaml
import Yesod.Handler
import Data.Maybe (fromJust)
import Yesod.Response (chooseRep)
import Control.Arrow
import Data.ByteString (ByteString)

#if TEST
import Control.Monad (replicateM)
import Test.Framework (testGroup, Test)
import Test.Framework.Providers.HUnit
import Test.Framework.Providers.QuickCheck (testProperty)
import Test.HUnit hiding (Test)
import Test.QuickCheck
import Control.Monad (when)
#endif

mkResources :: QuasiQuoter
mkResources = QuasiQuoter (strToExp True) undefined

mkResourcesNoCheck :: QuasiQuoter
mkResourcesNoCheck = QuasiQuoter (strToExp False) undefined

-- | Resource Pattern Piece
data RPP =
    Static String
    | DynStr String
    | DynInt String
    | Slurp String -- ^ take up the rest of the pieces. must be last
    deriving (Eq, Show)

-- | Resource Pattern
newtype RP = RP { unRP :: [RPP] }
    deriving (Eq, Show)

isSlurp :: RPP -> Bool
isSlurp (Slurp _) = True
isSlurp _ = False

data InvalidResourcePattern =
    SlurpNotLast String
    | EmptyResourcePatternPiece String
    deriving (Show, Typeable)
instance Exception InvalidResourcePattern
readRP :: MonadFailure InvalidResourcePattern m
       => ResourcePattern
       -> m RP
readRP "" = return $ RP []
readRP "/" = return $ RP []
readRP rps = fmap RP $ helper $ splitOn "/" $ correct rps where
    correct = correct1 . correct2 where
        correct1 ('/':rest) = rest
        correct1 x = x
        correct2 x
            | null x = x
            | last x == '/' = init x
            | otherwise = x
    helper [] = return []
    helper (('$':name):rest) = do
        rest' <- helper rest
        return $ DynStr name : rest'
    helper (('#':name):rest) = do
        rest' <- helper rest
        return $ DynInt name : rest'
    helper (('*':name):rest) = do
        rest' <- helper rest
        unless (null rest') $ failure $ SlurpNotLast rps
        return $ Slurp name : rest'
    helper ("":_) = failure $ EmptyResourcePatternPiece rps
    helper (name:rest) = do
        rest' <- helper rest
        return $ Static name : rest'
instance ConvertSuccess RP String where
    convertSuccess = concatMap helper . unRP where
        helper (Static s) = '/' : s
        helper (DynStr s) = '/' : '$' : s
        helper (Slurp s) = '/' : '*' : s
        helper (DynInt s) = '/' : '#' : s

type ResourcePattern = String

-- | Determing whether the given resource fits the resource pattern.
doesPatternMatch :: RP -> Resource -> Bool
doesPatternMatch rp r = case doPatternPiecesMatch (unRP rp) r of
                            Nothing -> False
                            _ -> True

-- | Extra the 'UrlParam's from a resource known to match the given 'RP'. This
-- is a partial function.
paramsFromMatchingPattern :: RP -> Resource -> [UrlParam]
paramsFromMatchingPattern rp =
    map snd . fromJust . doPatternPiecesMatch (unRP rp)

doPatternPiecesMatch :: MonadFailure NoMatch m
                   => [RPP]
                   -> Resource
                   -> m [(String, UrlParam)]
doPatternPiecesMatch rp r
    | not (null rp) && isSlurp (last rp) = do
        let rp' = init rp
            (r1, r2) = splitAt (length rp') r
        smap <- doPatternPiecesMatch rp' r1
        let Slurp slurpKey = last rp
        return $ (slurpKey, SlurpParam r2) : smap
    | length rp /= length r = failure NoMatch
    | otherwise = concat `fmap` zipWithM doesPatternPieceMatch rp r

data NoMatch = NoMatch
doesPatternPieceMatch :: MonadFailure NoMatch m
              => RPP
              -> String
              -> m [(String, UrlParam)]
doesPatternPieceMatch (Static x) y = if x == y then return [] else failure NoMatch
doesPatternPieceMatch (DynStr x) y = return [(x, StringParam y)]
doesPatternPieceMatch (Slurp x) _ = error $ "Slurp pattern " ++ x ++ " must be last"
doesPatternPieceMatch (DynInt x) y
    | all isDigit y = return [(x, IntParam $ read y)]
    | otherwise = failure NoMatch

-- | Determine if two resource patterns can lead to an overlap (ie, they can
-- both match a single resource).
overlaps :: [RPP] -> [RPP] -> Bool
overlaps [] [] = True
overlaps [] _ = False
overlaps _ [] = False
overlaps (Slurp _:_) _ = True
overlaps _ (Slurp _:_) = True
overlaps (DynStr _:x) (_:y) = overlaps x y
overlaps (_:x) (DynStr _:y) = overlaps x y
overlaps (DynInt _:x) (DynInt _:y) = overlaps x y
overlaps (DynInt _:x) (Static s:y)
    | all isDigit s = overlaps x y
    | otherwise = False
overlaps (Static s:x) (DynInt _:y)
    | all isDigit s = overlaps x y
    | otherwise = False
overlaps (Static a:x) (Static b:y) = a == b && overlaps x y

data OverlappingPatterns =
    OverlappingPatterns [(ResourcePattern, ResourcePattern)]
    deriving (Show, Typeable, Eq)
instance Exception OverlappingPatterns

getAllPairs :: [x] -> [(x, x)]
getAllPairs [] = []
getAllPairs [_] = []
getAllPairs (x:xs) = map ((,) x) xs ++ getAllPairs xs

-- | Ensures that we have a consistent set of resource patterns.
checkPatterns :: (MonadFailure OverlappingPatterns m,
                  MonadFailure InvalidResourcePattern m)
              => [ResourcePattern]
              -> m [RP]
checkPatterns rpss = do
    rps <- mapM (runKleisli $ Kleisli return &&& Kleisli readRP) rpss
    let overlaps' = concatMap helper $ getAllPairs rps
    unless (null overlaps') $ failure $ OverlappingPatterns overlaps'
    return $ map snd rps
        where
            helper :: ((ResourcePattern, RP), (ResourcePattern, RP))
                   -> [(ResourcePattern, ResourcePattern)]
            helper ((a, RP x), (b, RP y))
                | overlaps x y = [(a, b)]
                | otherwise = []

data RPNode = RPNode RP MethodMap
    deriving (Show, Eq)
data MethodMap = AllMethods String | Methods [(Method, String)]
    deriving (Show, Eq)
instance ConvertAttempt TextObject [RPNode] where
    convertAttempt = mapM helper <=< fromMapping where
        helper :: (Text, TextObject) -> Attempt RPNode
        helper (rp, rest) = do
            verbMap <- fromTextObject rest
            rp' <- readRP $ cs rp
            return $ RPNode rp' verbMap
instance ConvertAttempt TextObject MethodMap where
    convertAttempt (Scalar s) = return $ AllMethods $ cs s
    convertAttempt (Mapping m) = Methods `fmap` mapM helper m where
        helper :: (Text, TextObject) -> Attempt (Method, String)
        helper (v, Scalar f) = return (methodFromBS $ cs v, cs f)
        helper (_, x) = failure $ MethodMapNonScalar x
    convertAttempt o = failure $ MethodMapSequence o
data RPNodeException = MethodMapNonScalar TextObject
                     | MethodMapSequence TextObject
    deriving (Show, Typeable)
instance Exception RPNodeException

checkRPNodes :: (MonadFailure OverlappingPatterns m,
                 MonadFailure RepeatedMethod m,
                 MonadFailure InvalidResourcePattern m
                )
             => [RPNode]
             -> m [RPNode]
checkRPNodes nodes = do
    _ <- checkPatterns $ map (\(RPNode r _) -> cs r) nodes
    mapM_ (\(RPNode _ v) -> checkMethodMap v) nodes
    return nodes
        where
            checkMethodMap (AllMethods _) = return ()
            checkMethodMap (Methods vs) =
                let vs' = map fst vs
                    res = nub vs' == vs'
                 in unless res $ failure $ RepeatedMethod vs

newtype RepeatedMethod = RepeatedMethod [(Method, String)]
    deriving (Show, Typeable)
instance Exception RepeatedMethod

rpnodesTHCheck :: [RPNode] -> Q Exp
rpnodesTHCheck nodes = do
    nodes' <- runIO $ checkRPNodes nodes
    {- For debugging purposes
    rpnodesTH nodes' >>= runIO . putStrLn . pprint
    runIO $ hFlush stdout
    -}
    rpnodesTH nodes'

notFoundMethod :: Method -> Handler yesod a
notFoundMethod _verb = notFound

rpnodesTH :: [RPNode] -> Q Exp
rpnodesTH ns = do
    b <- mapM helper ns
    nfv <- [|notFoundMethod|]
    ow <- [|otherwise|]
    let b' = b ++ [(NormalG ow, nfv)]
    return $ LamE [VarP $ mkName "resource"]
           $ CaseE (TupE []) [Match WildP (GuardedB b') []]
      where
        helper :: RPNode -> Q (Guard, Exp)
        helper (RPNode rp vm) = do
            rp' <- lift rp
            cpb <- [|doesPatternMatch|]
            let r' = VarE $ mkName "resource"
            let g = cpb `AppE` rp' `AppE` r'
            vm' <- liftMethodMap vm r' rp
            let vm'' = LamE [VarP $ mkName "verb"] vm'
            return (NormalG g, vm'')

data UrlParam = SlurpParam { slurpParam :: [String] }
              | StringParam { stringParam :: String }
              | IntParam { intParam :: Integer }

getUrlParam :: RP -> Resource -> Int -> UrlParam
getUrlParam rp = (!!) . paramsFromMatchingPattern rp

getUrlParamSlurp :: RP -> Resource -> Int -> [String]
getUrlParamSlurp rp r = slurpParam . getUrlParam rp r

getUrlParamString :: RP -> Resource -> Int -> String
getUrlParamString rp r = stringParam . getUrlParam rp r

getUrlParamInt :: RP -> Resource -> Int -> Integer
getUrlParamInt rp r = intParam . getUrlParam rp r

applyUrlParams :: RP -> Exp -> Exp -> Q Exp
applyUrlParams rp@(RP rpps) r f = do
    getFs <- helper 0 rpps
    return $ foldl AppE f getFs
        where
            helper :: Int -> [RPP] -> Q [Exp]
            helper _ [] = return []
            helper i (Static _:rest) = helper i rest
            helper i (DynStr _:rest) = do
                rp' <- lift rp
                str <- [|getUrlParamString|]
                i' <- lift i
                rest' <- helper (i + 1) rest
                return $ str `AppE` rp' `AppE` r `AppE` i' : rest'
            helper i (DynInt _:rest) = do
                rp' <- lift rp
                int <- [|getUrlParamInt|]
                i' <- lift i
                rest' <- helper (i + 1) rest
                return $ int `AppE` rp' `AppE` r `AppE` i' : rest'
            helper i (Slurp _:rest) = do
                rp' <- lift rp
                slurp <- [|getUrlParamSlurp|]
                i' <- lift i
                rest' <- helper (i + 1) rest
                return $ slurp `AppE` rp' `AppE` r `AppE` i' : rest'

instance Lift RP where
    lift (RP rpps) = do
        rpps' <- lift rpps
        rp <- [|RP|]
        return $ rp `AppE` rpps'
instance Lift RPP where
    lift (Static s) = do
        st <- [|Static|]
        return $ st `AppE` (LitE $ StringL s)
    lift (DynStr s) = do
        d <- [|DynStr|]
        return $ d `AppE` (LitE $ StringL s)
    lift (DynInt s) = do
        d <- [|DynInt|]
        return $ d `AppE` (LitE $ StringL s)
    lift (Slurp s) = do
        sl <- [|Slurp|]
        return $ sl `AppE` (LitE $ StringL s)
liftMethodMap :: MethodMap -> Exp -> RP -> Q Exp
liftMethodMap (AllMethods s) r rp = do
    -- handler function
    let f = VarE $ mkName s
    -- applied to the verb
    let f' = f `AppE` VarE (mkName "verb")
    -- apply all the url params
    f'' <- applyUrlParams rp r f'
    -- and apply chooseRep
    cr <- [|fmap chooseRep|]
    let f''' = cr `AppE` f''
    return f'''
liftMethodMap (Methods vs) r rp = do
    cr <- [|fmap chooseRep|]
    vs' <- mapM (helper cr) vs
    return $ CaseE (TupE []) [Match WildP (GuardedB $ vs' ++ [whenNotFound]) []]
    --return $ CaseE (VarE $ mkName "verb") $ vs' ++ [whenNotFound]
        where
            helper :: Exp -> (Method, String) -> Q (Guard, Exp)
            helper cr (v, fName) = do
                method' <- liftMethod v
                equals <- [|(==)|]
                let eq = equals
                           `AppE` method'
                           `AppE` VarE ((mkName "verb"))
                let g = NormalG $ eq
                let f = VarE $ mkName fName
                f' <- applyUrlParams rp r f
                let f'' = cr `AppE` f'
                return (g, f'')
            whenNotFound :: (Guard, Exp)
            whenNotFound =
                (NormalG $ ConE $ mkName "True",
                 VarE $ mkName "notFound")

liftMethod :: Method -> Q Exp
liftMethod m = do
    cs' <- [|cs :: String -> ByteString|]
    methodFromBS' <- [|methodFromBS|]
    let s = cs $ methodToBS m :: String
    s' <- liftString s
    return $ methodFromBS' `AppE` AppE cs' s'

strToExp :: Bool -> String -> Q Exp
strToExp toCheck s = do
    rpnodes <- runIO $ decode (cs s) >>= \to -> convertAttemptWrap (to :: TextObject)
    (if toCheck then rpnodesTHCheck else rpnodesTH) rpnodes

#if TEST
---- Testing
testSuite :: Test
testSuite = testGroup "Yesod.Resource"
    [ testCase "non-overlap" caseOverlap1
    , testCase "overlap" caseOverlap2
    , testCase "overlap-slurp" caseOverlap3
    , testCase "checkPatterns" caseCheckPatterns
    , testProperty "show pattern" prop_showPattern
    , testCase "integers" caseIntegers
    , testCase "read patterns from YAML" caseFromYaml
    , testCase "checkRPNodes" caseCheckRPNodes
    , testCase "readRP" caseReadRP
    ]

instance Arbitrary RP where
    coarbitrary = undefined
    arbitrary = do
        size <- elements [1..10]
        rpps <- replicateM size arbitrary
        let rpps' = filter (not . isSlurp) rpps
        extra <- arbitrary
        return $ RP $ rpps' ++ [extra]

caseOverlap' :: String -> String -> Bool -> Assertion
caseOverlap' x y b = do
    x' <- readRP x
    y' <- readRP y
    assert $ overlaps (unRP x') (unRP y') == b

caseOverlap1 :: Assertion
caseOverlap1 = caseOverlap' "/foo/$bar/" "/foo/baz/$bin" False
caseOverlap2 :: Assertion
caseOverlap2 = caseOverlap' "/foo/bar" "/foo/$baz" True
caseOverlap3 :: Assertion
caseOverlap3 = caseOverlap' "/foo/bar/baz/$bin" "*slurp" True

caseCheckPatterns :: Assertion
caseCheckPatterns = do
    let res = checkPatterns [p1, p2, p3, p4, p5]
    attempt helper (fail "Did not fail") res
        where
            p1 = cs "/foo/bar/baz"
            p2 = cs "/foo/$bar/baz"
            p3 = cs "/bin"
            p4 = cs "/bin/boo"
            p5 = cs "/bin/*slurp"
            expected = OverlappingPatterns
                        [ (p1, p2)
                        , (p4, p5)
                        ]
            helper e = case cast e of
                        Nothing -> fail "Wrong exception"
                        Just op -> do
                            expected @=? op

prop_showPattern :: RP -> Bool
prop_showPattern p = readRP (cs p) == Just p

caseIntegers :: Assertion
caseIntegers = do
    let p1 = "/foo/#bar/"
        p2 = "/foo/#baz/"
        p3 = "/foo/$bin/"
        p4 = "/foo/4/"
        p5 = "/foo/bar/"
        p6 = "/foo/*slurp/"
        checkOverlap :: String -> String -> Bool -> IO ()
        checkOverlap a b c = do
            rpa <- readRP a
            rpb <- readRP b
            let res1 = overlaps (unRP rpa) (unRP $ rpb)
            let res2 = overlaps (unRP rpb) (unRP $ rpa)
            when (res1 /= c || res2 /= c) $ assertString $ a
               ++ (if c then " does not overlap with " else " overlaps with ")
               ++ b
    checkOverlap p1 p2 True
    checkOverlap p1 p3 True
    checkOverlap p1 p4 True
    checkOverlap p1 p5 False
    checkOverlap p1 p6 True

instance Arbitrary RPP where
    arbitrary = do
        constr <- elements [Static, DynStr, Slurp, DynInt]
        size <- elements [1..10]
        s <- replicateM size $ elements ['a'..'z']
        return $ constr s
    coarbitrary = undefined

caseFromYaml :: Assertion
caseFromYaml = do
    rp1 <- readRP "static/*filepath"
    rp2 <- readRP "page"
    rp3 <- readRP "page/$page"
    rp4 <- readRP "user/#id"
    let expected =
         [ RPNode rp1 $ AllMethods "getStatic"
         , RPNode rp2 $ Methods [(GET, "pageIndex"), (PUT, "pageAdd")]
         , RPNode rp3 $ Methods [ (GET, "pageDetail")
                              , (DELETE, "pageDelete")
                              , (POST, "pageUpdate")
                              ]
         , RPNode rp4 $ Methods [(GET, "userInfo")]
         ]
    contents' <- decodeFile "Test/resource-patterns.yaml"
    contents <- convertAttemptWrap (contents' :: TextObject)
    expected @=? contents

caseCheckRPNodes :: Assertion
caseCheckRPNodes = do
    good' <- decodeFile "Test/resource-patterns.yaml"
    good <- convertAttemptWrap (good' :: TextObject)
    Just good @=? checkRPNodes good
    rp1 <- readRP "foo/bar"
    rp2 <- readRP "$foo/bar"
    let bad1 = [ RPNode rp1 $ AllMethods "foo"
               , RPNode rp2 $ AllMethods "bar"
               ]
    Nothing @=? checkRPNodes bad1
    rp' <- readRP ""
    let bad2 = [RPNode rp' $ Methods [(GET, "foo"), (GET, "bar")]]
    Nothing @=? checkRPNodes bad2

caseReadRP :: Assertion
caseReadRP = do
    Just (RP [Static "foo", DynStr "bar", DynInt "baz", Slurp "bin"]) @=?
        readRP "foo/$bar/#baz/*bin/"
    Just (RP [Static "foo", DynStr "bar", DynInt "baz", Slurp "bin"]) @=?
        readRP "foo/$bar/#baz/*bin"
    Nothing @=? readRP "/foo//"
    Just (RP []) @=? readRP "/"
    Nothing @=? readRP "/*slurp/anything"
#endif
