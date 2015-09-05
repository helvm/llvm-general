{-# LANGUAGE
  TemplateHaskell,
  MultiParamTypeClasses,
  ConstraintKinds,
  QuasiQuotes,
  UndecidableInstances,
  RankNTypes
  #-}
module LLVM.General.Internal.Attribute where

import LLVM.General.Prelude

import LLVM.General.TH
import Language.Haskell.TH.Quote

import Control.Monad.AnyCont
import Control.Monad.Exceptable
import Control.Monad.State (gets)

import Foreign.C (CUInt)
import Foreign.Ptr
import Data.Either
import Data.List (genericSplitAt)
import Data.Bits
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Maybe

import qualified LLVM.General.Internal.FFI.Attribute as FFI
import qualified LLVM.General.Internal.FFI.LLVMCTypes as FFI
import LLVM.General.Internal.FFI.LLVMCTypes (parameterAttributeKindP, functionAttributeKindP)  

import qualified LLVM.General.AST.Attribute as A.A
import qualified LLVM.General.AST.ParameterAttribute as A.PA  
import qualified LLVM.General.AST.FunctionAttribute as A.FA  

import LLVM.General.Internal.Coding
import LLVM.General.Internal.Context  
import LLVM.General.Internal.EncodeAST
import LLVM.General.Internal.DecodeAST

$(do
  let
    -- build an instance of the Coding class for lists of some kind of attribute
    genAttributeListCoding :: (Data a, Bits a) => TypeQ -> Name -> [(a, String)] -> DecsQ
    genAttributeListCoding type' ctn attributeData = do
      let
         lowZeroes :: Bits b => b -> Int
         lowZeroes b | testBit b 0 = 0
         lowZeroes b = 1 + lowZeroes (shiftR b 1)
         field :: Bits b => b -> (Int, Int)
         field b = 
             let s = lowZeroes b
                 w = lowZeroes (complement (shiftR b s))
             in 
               (s,w)
         attributeData' = [(mkName n, b, s,w) | (b,n) <- attributeData, let (s,w) = field b ]
      let m = varT . mkName $ "m"
      TyConI (NewtypeD _ _ _ (NormalC ctcn _) _) <- reify ctn
      let zero = [| $(conE ctcn) 0 |]
      sequence [
        instanceD (sequence [appT (conT ''Monad) m]) [t| EncodeM $(m) [$(type')] $(conT ctn) |] [
          funD (mkName "encodeM") [
            clause [] (normalB [| return . (
              let
                 encodeAlignment a | popCount a == 1 = 1 + popCount (a - 1)
                 encodeAlignment _ = error "Cannot encode alignment which is not a power of two"
                 encodeAttribute a = $(
                  caseE [| a |] $ flip map attributeData' $ \(n, b, s, w) ->
                    let bQ = (dataToExpQ (const Nothing) b)
                    in
                      case w of
                        1 -> match (conP n []) (normalB bQ) []
                        _ -> do 
                          a <- newName "a"
                          match 
                           (conP n [varP a])
                           (normalB [| ($(conE ctcn) (fromIntegral (encodeAlignment $(varE a)) `shiftL` s)) .&. $(bQ) |])
                           []
                  )
              in
                foldl (.|.) $(zero) . map encodeAttribute
             ) |]) []
           ]
         ],
 
        -- build a decoder which uses bit masking for multiple fields at once
        -- to eliminate multiple absent attributes in fewer tests
        instanceD (sequence [appT (conT ''Monad) m]) [t| DecodeM $(m) [$(type')] $(conT ctn) |] [
          funD (mkName "decodeM") [
            do
              bits <- newName "bits"
              clause [varP bits] (normalB 
                (let
                    code :: (Data a, Bits a) => [ (Name, a, Int, Int) ] -- attrs to handle
                         -> Int -- length (attrs), passed in to avoid recomputation
                         -> (a, ExpQ) -- (<bitmask for all the given attrs>, <code to decode the given attrs>)
                    code [(n, b, s, w)] _ = (
                       b, 
                       case w of
                         1 -> [| [ $(conE n) | testBit $(varE bits) s ] |]
                         _-> [| 
                               [ 
                                 $(do
                                    i' <- newName "i'"
                                    letE 
                                     [valD (conP ctcn [varP i']) (normalB [| i |]) []]
                                     [| $(conE n) (bit ((fromIntegral $(varE i')) - 1)) |])
                                 | let i = ($(varE bits) .&. $(dataToExpQ (const Nothing) b)) `shiftR` s, 
                                   i /= $(zero)
                               ]
                             |]
                      )
                    code attrs nAttrs =
                      let (nEarlyAttrs, nLateAttrs) = (nAttrs `div` 2, nAttrs - nEarlyAttrs)
                          (earlyAttrs, lateAttrs) = genericSplitAt nEarlyAttrs attrs
                          (earlyAttrBits, earlyAttrCode) = code earlyAttrs nEarlyAttrs
                          (lateAttrBits, lateAttrCode) = code lateAttrs nLateAttrs
                          attrBits = earlyAttrBits .|. lateAttrBits
                      in
                        (
                         attrBits, 
                         [| 
                            if ($(varE bits) .&. $(dataToExpQ (const Nothing) attrBits) /= $(zero)) then
                              ($earlyAttrCode ++ $lateAttrCode) 
                            else
                              []
                          |]
                        )
                in
                  [| return $(snd $ code attributeData' (length attributeData')) |]
                )
               ) []
            ]
          ]
        ]

  pi <- genAttributeListCoding [t| A.A.ParameterAttribute |] ''FFI.ParamAttr [
    (FFI.paramAttrZExt, "A.A.ZeroExt"),
    (FFI.paramAttrSExt, "A.A.SignExt"),
    (FFI.paramAttrInReg, "A.A.InReg"),
    (FFI.paramAttrStructRet, "A.A.SRet"),
    (FFI.paramAttrAlignment, "A.A.Alignment"),
    (FFI.paramAttrNoAlias, "A.A.NoAlias"),
    (FFI.paramAttrByVal, "A.A.ByVal"),
    (FFI.paramAttrNoCapture, "A.A.NoCapture"),
    (FFI.paramAttrNest, "A.A.Nest")
   ]

  fi <- genAttributeListCoding [t| A.A.FunctionAttribute |] ''FFI.FunctionAttr [
    (FFI.functionAttrNoReturn, "A.A.NoReturn"),
    (FFI.functionAttrNoUnwind, "A.A.NoUnwind"),
    (FFI.functionAttrReadNone, "A.A.ReadNone"),
    (FFI.functionAttrReadOnly, "A.A.ReadOnly"),
    (FFI.functionAttrNoInline, "A.A.NoInline"),
    (FFI.functionAttrAlwaysInline, "A.A.AlwaysInline"),
    (FFI.functionAttrOptimizeForSize, "A.A.OptimizeForSize"),
    (FFI.functionAttrStackProtect, "A.A.StackProtect"),
    (FFI.functionAttrStackProtectReq, "A.A.StackProtectReq"),
    (FFI.functionAttrNoRedZone, "A.A.NoRedZone"),
    (FFI.functionAttrNoImplicitFloat, "A.A.NoImplicitFloat"),
    (FFI.functionAttrNaked, "A.A.Naked"),
    (FFI.functionAttrInlineHint, "A.A.InlineHint"),
    (FFI.functionAttrStackAlignment, "A.A.StackAlignment"),
    (FFI.functionAttrReturnsTwice, "A.A.ReturnsTwice"),
    (FFI.functionAttrUWTable, "A.A.UWTable"),
    (FFI.functionAttrNonLazyBind, "A.A.NonLazyBind")
   ]
  return (pi ++ fi)
 )

instance EncodeM EncodeAST [Either A.FA.GroupID A.FA.FunctionAttribute] FFI.FunctionAttributeSet where
  encodeM fas = do
{-
    let (gids, as) = partitionEithers fas
    as <- (encodeM as :: EncodeAST FFI.FunctionAttributeSet)
    gs <- mapM referAttributeGroup gids
-}
    return $ error "EncodeM to FFI.FunctionAttributeSet nyi"

instance Monad m => EncodeM m A.PA.ParameterAttribute (Ptr FFI.ParameterAttrBuilder -> EncodeAST ()) where
  encodeM a = return $ \b -> liftIO $ case a of
    A.PA.Alignment v -> FFI.attrBuilderAddAlignment b v
    A.PA.Dereferenceable v -> FFI.attrBuilderAddDereferenceable b v
    _ -> FFI.attrBuilderAddParameterAttributeKind b $ case a of
      A.PA.ZeroExt -> FFI.parameterAttributeKindZExt
      A.PA.SignExt -> FFI.parameterAttributeKindSExt
      A.PA.InReg -> FFI.parameterAttributeKindInReg
      A.PA.SRet -> FFI.parameterAttributeKindStructRet
      A.PA.NoAlias -> FFI.parameterAttributeKindNoAlias
      A.PA.ByVal -> FFI.parameterAttributeKindByVal
      A.PA.NoCapture -> FFI.parameterAttributeKindNoCapture
      A.PA.Nest -> FFI.parameterAttributeKindNest
      A.PA.ReadOnly -> FFI.parameterAttributeKindReadOnly
      A.PA.ReadNone -> FFI.parameterAttributeKindReadNone
      A.PA.InAlloca -> FFI.parameterAttributeKindInAlloca
      A.PA.NonNull -> FFI.parameterAttributeKindNonNull
      A.PA.Returned -> FFI.parameterAttributeKindReturned

instance Monad m => EncodeM m A.FA.FunctionAttribute (Ptr FFI.FunctionAttrBuilder -> EncodeAST ()) where
  encodeM (A.FA.StringAttribute kind value) = return $ \b -> do
    (kindP, kindLen) <- encodeM kind
    (valueP, valueLen) <- encodeM value
    liftIO $ FFI.attrBuilderAddStringAttribute b kindP kindLen valueP valueLen
  encodeM a = return $ \b -> liftIO $ case a of
    A.FA.StackAlignment v -> FFI.attrBuilderAddStackAlignment b v
    _ -> FFI.attrBuilderAddFunctionAttributeKind b $ case a of
      A.FA.NoReturn -> FFI.functionAttributeKindNoReturn
      A.FA.NoUnwind -> FFI.functionAttributeKindNoUnwind
      A.FA.ReadNone -> FFI.functionAttributeKindReadNone
      A.FA.ReadOnly -> FFI.functionAttributeKindReadOnly
      A.FA.NoInline -> FFI.functionAttributeKindNoInline
      A.FA.AlwaysInline -> FFI.functionAttributeKindAlwaysInline
      A.FA.MinimizeSize -> FFI.functionAttributeKindMinSize
      A.FA.OptimizeForSize -> FFI.functionAttributeKindOptimizeForSize
      A.FA.OptimizeNone -> FFI.functionAttributeKindOptimizeForSize                                                   
      A.FA.StackProtect -> FFI.functionAttributeKindStackProtect
      A.FA.StackProtectReq -> FFI.functionAttributeKindStackProtectReq
      A.FA.StackProtectStrong -> FFI.functionAttributeKindStackProtectStrong
      A.FA.NoRedZone -> FFI.functionAttributeKindNoRedZone
      A.FA.NoImplicitFloat -> FFI.functionAttributeKindNoImplicitFloat
      A.FA.Naked -> FFI.functionAttributeKindNaked
      A.FA.InlineHint -> FFI.functionAttributeKindInlineHint
      A.FA.ReturnsTwice -> FFI.functionAttributeKindReturnsTwice
      A.FA.UWTable -> FFI.functionAttributeKindUWTable
      A.FA.NonLazyBind -> FFI.functionAttributeKindNonLazyBind
      A.FA.Builtin -> FFI.functionAttributeKindBuiltin
      A.FA.NoBuiltin -> FFI.functionAttributeKindNoBuiltin
      A.FA.Cold -> FFI.functionAttributeKindCold
      A.FA.JumpTable -> FFI.functionAttributeKindJumpTable
      A.FA.NoDuplicate -> FFI.functionAttributeKindNoDuplicate
      A.FA.SanitizeAddress -> FFI.functionAttributeKindSanitizeAddress
      A.FA.SanitizeThread -> FFI.functionAttributeKindSanitizeThread
      A.FA.SanitizeMemory -> FFI.functionAttributeKindSanitizeMemory

instance DecodeM DecodeAST A.PA.ParameterAttribute FFI.ParameterAttribute where
  decodeM a = do
    enum <- liftIO $ FFI.parameterAttributeKindAsEnum a
    case enum of
      [parameterAttributeKindP|ZExt|] -> return A.PA.ZeroExt
      [parameterAttributeKindP|SExt|] -> return A.PA.SignExt
      [parameterAttributeKindP|InReg|] -> return A.PA.InReg
      [parameterAttributeKindP|StructRet|] -> return A.PA.SRet
      [parameterAttributeKindP|Alignment|] -> return A.PA.Alignment `ap` (liftIO $ FFI.attributeValueAsInt a)
      [parameterAttributeKindP|NoAlias|] -> return A.PA.NoAlias
      [parameterAttributeKindP|ByVal|] -> return A.PA.ByVal
      [parameterAttributeKindP|NoCapture|] -> return A.PA.NoCapture
      [parameterAttributeKindP|Nest|] -> return A.PA.Nest
      [parameterAttributeKindP|ReadOnly|] -> return A.PA.ReadOnly
      [parameterAttributeKindP|ReadNone|] -> return A.PA.ReadNone
      [parameterAttributeKindP|InAlloca|] -> return A.PA.InAlloca
      [parameterAttributeKindP|NonNull|] -> return A.PA.NonNull
      [parameterAttributeKindP|Dereferenceable|] -> return A.PA.Dereferenceable `ap` (liftIO $ FFI.attributeValueAsInt a)
      [parameterAttributeKindP|Returned|] -> return A.PA.Returned
      _ -> error $ "unhandled parameter attribute enum value: " ++ show enum

instance DecodeM DecodeAST A.FA.FunctionAttribute FFI.FunctionAttribute where
  decodeM a = do
    isString <- decodeM =<< (liftIO $ FFI.isStringAttribute a)
    if isString
       then
         return A.FA.StringAttribute
                  `ap` (decodeM $ FFI.attributeKindAsString a)
                  `ap` (decodeM $ FFI.attributeValueAsString a)                   
       else do
         enum <- liftIO $ FFI.functionAttributeKindAsEnum a
         case enum of
           [functionAttributeKindP|NoReturn|] -> return A.FA.NoReturn
           [functionAttributeKindP|NoUnwind|] -> return A.FA.NoUnwind
           [functionAttributeKindP|ReadNone|] -> return A.FA.ReadNone
           [functionAttributeKindP|ReadOnly|] -> return A.FA.ReadOnly
           [functionAttributeKindP|NoInline|] -> return A.FA.NoInline
           [functionAttributeKindP|AlwaysInline|] -> return A.FA.AlwaysInline
           [functionAttributeKindP|MinSize|] -> return A.FA.MinimizeSize
           [functionAttributeKindP|OptimizeForSize|] -> return A.FA.OptimizeForSize
           [functionAttributeKindP|OptimizeNone|] -> return A.FA.OptimizeForSize                                                   
           [functionAttributeKindP|StackProtect|] -> return A.FA.StackProtect
           [functionAttributeKindP|StackProtectReq|] -> return A.FA.StackProtectReq
           [functionAttributeKindP|StackProtectStrong|] -> return A.FA.StackProtectStrong
           [functionAttributeKindP|NoRedZone|] -> return A.FA.NoRedZone
           [functionAttributeKindP|NoImplicitFloat|] -> return A.FA.NoImplicitFloat
           [functionAttributeKindP|Naked|] -> return A.FA.Naked
           [functionAttributeKindP|InlineHint|] -> return A.FA.InlineHint
           [functionAttributeKindP|StackAlignment|] -> return A.FA.StackAlignment `ap` (liftIO $ FFI.attributeValueAsInt a)
           [functionAttributeKindP|ReturnsTwice|] -> return A.FA.ReturnsTwice
           [functionAttributeKindP|UWTable|] -> return A.FA.UWTable
           [functionAttributeKindP|NonLazyBind|] -> return A.FA.NonLazyBind
           [functionAttributeKindP|Builtin|] -> return A.FA.Builtin
           [functionAttributeKindP|NoBuiltin|] -> return A.FA.NoBuiltin
           [functionAttributeKindP|Cold|] -> return A.FA.Cold
           [functionAttributeKindP|JumpTable|] -> return A.FA.JumpTable
           [functionAttributeKindP|NoDuplicate|] -> return A.FA.NoDuplicate
           [functionAttributeKindP|SanitizeAddress|] -> return A.FA.SanitizeAddress
           [functionAttributeKindP|SanitizeThread|] -> return A.FA.SanitizeThread
           [functionAttributeKindP|SanitizeMemory|] -> return A.FA.SanitizeMemory
           _ -> error $ "unhandled function attribute enum value: " ++ show enum
            
allocaAttrBuilder :: (Monad m, MonadAnyCont IO m) => m (Ptr (FFI.AttrBuilder a))
allocaAttrBuilder = do
  p <- allocaArray FFI.getAttrBuilderSize
  anyContToM $ \f -> do
    ab <- FFI.constructAttrBuilder p
    r <- f ab
    FFI.destroyAttrBuilder ab
    return r

instance EncodeM EncodeAST a (Ptr (FFI.AttrBuilder b) -> EncodeAST ()) => EncodeM EncodeAST (FFI.Index, [a]) (FFI.AttributeSet b) where
  encodeM (index, as) = scopeAnyCont $ do
    ab <- allocaAttrBuilder
    builds <- mapM encodeM as
    forM builds ($ ab) :: EncodeAST [()]
    Context context <- gets encodeStateContext
    liftIO $ FFI.getAttributeSet context index ab

instance EncodeM EncodeAST [A.FA.FunctionAttribute] FFI.FunctionAttributeSet where
  encodeM fas = encodeM (FFI.functionIndex, fas)

instance DecodeM DecodeAST a (FFI.Attribute b) => DecodeM DecodeAST [a] (FFI.AttributeSet b) where
  decodeM as = do
    np <- alloca
    as <- liftIO $ FFI.attributeSetGetAttributes as 0 np
    n <- peek np
    decodeM (n, as)
            
data MixedAttributeSet = MixedAttributeSet {
    functionAttributes :: [Either A.FA.GroupID A.FA.FunctionAttribute],
    returnAttributes :: [A.PA.ParameterAttribute],
    parameterAttributes :: Map CUInt [A.PA.ParameterAttribute]
  }
  deriving (Eq, Show)

data PreSlot
  = IndirectFunctionAttributes A.FA.GroupID
  | DirectFunctionAttributes [A.FA.FunctionAttribute]
  | ReturnAttributes [A.PA.ParameterAttribute]
  | ParameterAttributes CUInt [A.PA.ParameterAttribute]    

instance EncodeM EncodeAST PreSlot FFI.MixedAttributeSet where
  encodeM preSlot = do
    let forget = liftM FFI.forgetAttributeType
    case preSlot of
      IndirectFunctionAttributes gid -> forget (referAttributeGroup gid)
      DirectFunctionAttributes fas -> forget (encodeM fas :: EncodeAST FFI.FunctionAttributeSet)
      ReturnAttributes as -> forget (encodeM (FFI.returnIndex, as) :: EncodeAST FFI.ParameterAttributeSet)
      ParameterAttributes i as -> forget (encodeM (fromIntegral (i + 1) :: FFI.Index, as) :: EncodeAST FFI.ParameterAttributeSet)

instance EncodeM EncodeAST MixedAttributeSet FFI.MixedAttributeSet where
  encodeM (MixedAttributeSet fAttrs rAttrs pAttrs) = do
    let directP = DirectFunctionAttributes (rights fAttrs)
        indirectPs = map IndirectFunctionAttributes (lefts fAttrs)
        returnP = ReturnAttributes rAttrs
        paramPs = [ ParameterAttributes x as | (x, as) <- Map.toList pAttrs ]
    (nAttrs, attrs) <- encodeM ([directP, returnP] ++ indirectPs ++ paramPs)
    Context context <- gets encodeStateContext
    liftIO $ FFI.mixAttributeSets context attrs nAttrs

instance DecodeM DecodeAST MixedAttributeSet FFI.MixedAttributeSet where
  decodeM mas = do
    numSlots <- if mas == nullPtr then return 0 else liftIO $ FFI.attributeSetNumSlots mas
    slotIndexes <- forM (take (fromIntegral numSlots) [0..]) $ \s -> do
      i <- liftIO $ FFI.attributeSetSlotIndex mas s
      return (i, s)
    let separate :: Ord k => k -> Map k a -> (Maybe a, Map k a)
        separate = Map.updateLookupWithKey (\_ _ -> Nothing)
        indexedSlots = Map.fromList slotIndexes
    unless (Map.size indexedSlots == length slotIndexes) $
           fail "unexpected slot index collision decoding mixed AttributeSet"
    let (functionSlot, otherSlots) = separate FFI.functionIndex (Map.fromList slotIndexes)
    functionAnnotation <- for (maybeToList functionSlot) $ \slot -> do
      a <- liftIO $ FFI.attributeSetSlotAttributes mas slot
      getAttributeGroupID a
    otherAttributeSets <- for otherSlots $ \slot -> do
      a <- liftIO $ FFI.attributeSetSlotAttributes mas slot
      decodeM (a :: FFI.ParameterAttributeSet)
    let (returnAttributeSet, shiftedParameterAttributeSets) = separate FFI.returnIndex otherAttributeSets
    return $ MixedAttributeSet {
                  functionAttributes = fmap Left functionAnnotation,
                  returnAttributes = join . maybeToList $ returnAttributeSet,
                  parameterAttributes = Map.mapKeysMonotonic (\x -> fromIntegral x - 1) shiftedParameterAttributeSets
                }

