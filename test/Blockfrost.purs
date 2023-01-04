module Test.Ctl.Blockfrost (main, suite) where

import Prelude

import Aeson (class DecodeAeson, decodeJsonString)
import Contract.Test.Mote (TestPlanM, interpretWithConfig)
import Control.Monad.Error.Class (liftEither)
import Test.Spec.Runner (defaultConfig)
import Mote (group, test)
import Ctl.Internal.Service.Blockfrost
  ( BlockfrostProtocolParameters(BlockfrostProtocolParameters)
  )
import Data.Bifunctor (lmap)
import Effect (Effect)
import Effect.Aff (Aff, error, launchAff_)
import Node.Encoding (Encoding(UTF8))
import Node.FS.Aff (readTextFile)
import Test.Spec.Assertions (shouldEqual)

-- These fixtures were aquired soon after each other, so we can compare their
-- parsed results

blockfrostFixture :: String
blockfrostFixture =
  "blockfrost/getProtocolParameters-7fe834fd628aa322eedeb3d8c7c1dd61.json"

ogmiosFixture :: String
ogmiosFixture =
  "ogmios/currentProtocolParameters-9f10850f285b1493955267e900008841.json"

loadFixture :: forall (a :: Type). DecodeAeson a => String -> Aff a
loadFixture fixture =
  readTextFile UTF8 ("fixtures/test/" <> fixture)
    <#> decodeJsonString >>> lmap (show >>> error)
    >>= liftEither

main :: Effect Unit
main = launchAff_ do
  interpretWithConfig
    defaultConfig
    suite

suite :: TestPlanM (Aff Unit) Unit
suite = do
  group "Blockfrost" do
    test "ProtocolParameter parsing" do
      BlockfrostProtocolParameters blockfrostFixture' <- loadFixture
        blockfrostFixture
      ogmiosFixture' <- loadFixture ogmiosFixture

      blockfrostFixture' `shouldEqual` ogmiosFixture'
