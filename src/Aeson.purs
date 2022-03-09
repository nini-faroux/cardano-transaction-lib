-- | Argonaut can't decode long integers the way Aeson encodes them: they
-- | lose precision on the stage of `JSON.parse` call, which we can't really
-- | control. This module is a hacky solution allowing us to preserve long
-- | integers while decoding.
-- | The idea is that we process JSON-as-string in FFI, exctracting all numbers
-- | into a separate array named "index", where they are represented as strings,
-- | and place that index alongside the original json. We modify the original
-- | JSON such that it contains indices of original numbers in the array,
-- | instead of the actual numbers.
-- |
-- | E.g. from `{ "a": 42, "b": 24 }` we get
-- | `{ json: {"a": 0, "b": 1 }, index: [ "42", "24" ] }`.
-- |
-- | Then, in decoders for `Int` and `BigInt` we access that array to get the
-- | values back.
-- |
-- | Known limitations: does not support Record decoding (no GDecodeJson-like
-- | machinery). But it is possible to decode records manually, because
-- | `getField` is implemented.
-- |
-- | Does not support optional fields because they're not needeed yet, but this
-- |  functionality can be adapted from argonaut similarly to `getField`.
module Aeson
  ( NumberIndex
  , class DecodeAeson
  , class DecodeAesonField
  , class GDecodeAeson
  , Aeson
  , AesonCases
  , (.:)
  , caseAeson
  , constAesonCases
  , decodeAeson
  , decodeAesonField
  , gDecodeAeson
  , decodeAesonString
  , getField
  , getNestedAeson
  , jsonToAeson
  , parseJsonStringToAeson
  , toObject
  , toStringifiedNumbersJson
  ) where

import Prelude

import Control.Lazy (fix)
import Data.Argonaut
  ( class DecodeJson
  , Json
  , JsonDecodeError
      ( TypeMismatch
      , AtKey
      , MissingValue
      , UnexpectedValue
      )
  , caseJson
  , caseJsonObject
  , decodeJson
  , fromArray
  , fromObject
  , jsonNull
  , stringify
  )
import Data.Argonaut.Encode.Encoders (encodeBoolean, encodeString)
import Data.Argonaut.Parser (jsonParser)
import Data.Array (foldM)
import Data.Array as Array
import Data.Bifunctor (lmap)
import Data.BigInt (BigInt)
import Data.BigInt as BigInt
import Data.Either
  ( Either(Left, Right)
  , fromRight
  , hush
  , note
  )
import Data.Int (round)
import Data.Int as Int
import Data.Maybe (Maybe(Just, Nothing), maybe)
import Data.Symbol (class IsSymbol, reflectSymbol)
import Data.Traversable (class Traversable, for)
import Data.Typelevel.Undefined (undefined)
import Foreign.Object (Object)
import Foreign.Object as FO
import Partial.Unsafe (unsafePartial)
import Prim.Row as Row
import Prim.RowList as RL
import Record as Record
import Type.Prelude (Proxy(Proxy))

-- | A piece of JSON where all numbers are replaced with their indexes
newtype AesonPatchedJson = AesonPatchedJson Json

-- | A piece of JSON where all numbers are extracted into `NumberIndex`.
newtype Aeson = Aeson { patchedJson :: AesonPatchedJson, numberIndex :: NumberIndex }

-- | A list of numbers extracted from Json, as they appear in the payload.
type NumberIndex = Array String

class DecodeAeson (a :: Type) where
  decodeAeson :: Aeson -> Either JsonDecodeError a

-------- Parsing: String -> Aeson --------

foreign import parseJsonExtractingIntegers
  :: String
  -> { patchedPayload :: String, numberIndex :: NumberIndex }

parseJsonStringToAeson :: String -> Either JsonDecodeError Aeson
parseJsonStringToAeson payload = do
  let { patchedPayload, numberIndex } = parseJsonExtractingIntegers payload
  patchedJson <- note MissingValue $ hush $ AesonPatchedJson <$> jsonParser patchedPayload
  pure $ Aeson { numberIndex, patchedJson }

-------- Json <-> Aeson --------

-- | Replaces indexes in the Aeson's payload with stringified
-- | numbers from numberIndex.
-- | Given original payload of: `{"a": 10}`
-- | The result will be an Json object representing: `{"a": "10"}`
toStringifiedNumbersJson :: Aeson -> Json
toStringifiedNumbersJson = fix \_ ->
  caseAeson
    { caseNull: const jsonNull
    , caseBoolean: encodeBoolean
    , caseNumber: encodeString
    , caseString: encodeString
    , caseArray: map toStringifiedNumbersJson >>> fromArray
    , caseObject: map toStringifiedNumbersJson >>> fromObject
    }

-- | Recodes Json to Aeson.
-- | NOTE. The operation is costly as its stringifies given Json
-- |       and reparses resulting string as Aeson.
jsonToAeson :: Json -> Aeson
jsonToAeson = stringify >>> decodeAesonString >>> fromRight shouldNotHappen
  where
  -- valid json should always decode without errors
  shouldNotHappen = undefined

-------- Aeson manipulation and field accessors --------

-- TODO: add getFieldOptional if ever needed.
getField
  :: forall (a :: Type)
   . DecodeAeson a
  => FO.Object Aeson
  -> String
  -> Either JsonDecodeError a
getField aesonObject field = getField' decodeAeson aesonObject field

infix 7 getField as .:

-- | Adapted from `Data.Argonaut.Decode.Decoders`
getField'
  :: forall (a :: Type)
   . (Aeson -> Either JsonDecodeError a)
  -> FO.Object Aeson
  -> String
  -> Either JsonDecodeError a
getField' decoder obj str =
  maybe
    (Left $ AtKey str MissingValue)
    (lmap (AtKey str) <<< decoder)
    (FO.lookup str obj)

-- | Returns an Aeson available under a sequence of keys in given Aeson.
-- | If not possible returns JsonDecodeError.
getNestedAeson :: Aeson -> Array String -> Either JsonDecodeError Aeson
getNestedAeson asn@(Aeson { numberIndex, patchedJson: AesonPatchedJson pjson }) keys =
  note (UnexpectedValue $ toStringifiedNumbersJson asn) $
    mkAeson <$> (foldM lookup pjson keys :: Maybe Json)
  where
  lookup :: Json -> String -> Maybe Json
  lookup j lbl = caseJsonObject Nothing (FO.lookup lbl) j

  mkAeson :: Json -> Aeson
  mkAeson json = Aeson { numberIndex, patchedJson: AesonPatchedJson json }


-- | Utility abbrevation. See `caseAeson` for an example usage.
type AesonCases a =
  { caseNull :: Unit -> a
  , caseBoolean :: Boolean -> a
  , caseNumber :: String -> a
  , caseString :: String -> a
  , caseArray :: Array Aeson -> a
  , caseObject :: Object Aeson -> a
  }

caseAeson
  :: forall a
   . AesonCases a
  -> Aeson
  -> a
caseAeson
  { caseNull, caseBoolean, caseNumber, caseString, caseArray, caseObject }
  (Aeson { numberIndex, patchedJson: AesonPatchedJson pJson }) = caseJson
  caseNull
  caseBoolean
  (coerceNumber >>> unsafeIndex numberIndex >>> caseNumber)
  caseString
  (map mkAeson >>> caseArray)
  (map mkAeson >>> caseObject)
  pJson
  where
  mkAeson :: Json -> Aeson
  mkAeson json = Aeson { patchedJson: AesonPatchedJson json, numberIndex }

  -- will never get index out of bounds
  unsafeIndex :: forall (x :: Type). Array x -> Int -> x
  unsafeIndex arr ix = unsafePartial $ Array.unsafeIndex arr ix

  -- will never encounter non int number
  coerceNumber :: Number -> Int
  coerceNumber = round

constAesonCases :: forall (a :: Type). a -> AesonCases a
constAesonCases v =
  { caseObject: c, caseNull: c, caseBoolean: c, caseString: c, caseNumber: c, caseArray: c }
  where
    c :: forall (b :: Type). b -> a
    c = const v

toObject :: Aeson -> Maybe (Object Aeson)
toObject =
  caseAeson $ constAesonCases Nothing # _ { caseObject = Just }

-------- Decode helpers --------

-- | Ignore numeric index and reuse Argonaut decoder.
decodeAesonViaJson
  :: forall (a :: Type). DecodeJson a => Aeson -> Either JsonDecodeError a
decodeAesonViaJson (Aeson { patchedJson: AesonPatchedJson j }) = decodeJson j

decodeAesonString
  :: forall (a :: Type). DecodeAeson a => String -> Either JsonDecodeError a
decodeAesonString = parseJsonStringToAeson >=> decodeAeson

-------- DecodeAeson instances --------

instance DecodeAeson Int where
  decodeAeson aeson@(Aeson { numberIndex }) = do
    -- Numbers are replaced by their index in the array.
    ix <- decodeAesonViaJson aeson
    numberStr <- note MissingValue (numberIndex Array.!! ix)
    note MissingValue $ Int.fromString numberStr

instance DecodeAeson BigInt where
  decodeAeson aeson@(Aeson { numberIndex }) = do
    -- Numbers are replaced by their index in the array.
    ix <- decodeAesonViaJson aeson
    numberStr <- note MissingValue (numberIndex Array.!! ix)
    note MissingValue $ BigInt.fromString numberStr

instance DecodeAeson Boolean where
  decodeAeson = decodeAesonViaJson

instance DecodeAeson String where
  decodeAeson = decodeAesonViaJson

instance DecodeAeson Number where
  decodeAeson = decodeAesonViaJson

instance DecodeAeson Json where
  decodeAeson = Right <<< toStringifiedNumbersJson

instance DecodeAeson Aeson where
  decodeAeson = pure

instance (GDecodeAeson row list, RL.RowToList row list) => DecodeAeson (Record row) where
  decodeAeson json =
    case toObject json of
      Just object -> gDecodeAeson object (Proxy :: Proxy list)
      Nothing -> Left $ TypeMismatch "Object"

else instance (Traversable t, DecodeAeson a, DecodeJson (t Json)) => DecodeAeson (t a) where
  decodeAeson (Aeson { numberIndex, patchedJson: AesonPatchedJson pJson }) = do
    jsons :: t _ <- map AesonPatchedJson <$> decodeJson pJson
    for jsons (\patchedJson -> decodeAeson (Aeson { patchedJson, numberIndex }))

class GDecodeAeson (row :: Row Type) (list :: RL.RowList Type) | list -> row where
  gDecodeAeson :: forall proxy. FO.Object Aeson -> proxy list -> Either JsonDecodeError (Record row)

instance GDecodeAeson () RL.Nil where
  gDecodeAeson _ _ = Right {}

instance
  ( DecodeAesonField value
  , GDecodeAeson rowTail tail
  , IsSymbol field
  , Row.Cons field value rowTail row
  , Row.Lacks field rowTail
  ) =>
  GDecodeAeson row (RL.Cons field value tail) where
  gDecodeAeson object _ = do
    let
      _field = Proxy :: Proxy field
      fieldName = reflectSymbol _field
      fieldValue = FO.lookup fieldName object

    case decodeAesonField fieldValue of
      Just fieldVal -> do
        val <- lmap (AtKey fieldName) fieldVal
        rest <- gDecodeAeson object (Proxy :: Proxy tail)
        Right $ Record.insert _field val rest

      Nothing ->
        Left $ AtKey fieldName MissingValue

class DecodeAesonField a where
  decodeAesonField :: Maybe Aeson -> Maybe (Either JsonDecodeError a)

instance DecodeAeson a => DecodeAesonField (Maybe a) where
  decodeAesonField Nothing = Just $ Right Nothing
  decodeAesonField (Just j) = Just $ decodeAeson j

else instance DecodeAeson a => DecodeAesonField a where
  decodeAesonField j = decodeAeson <$> j
