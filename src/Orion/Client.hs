{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Orion.Client where

import Network.Wreq as W
import Control.Lens hiding ((.=))
import Data.Aeson as JSON
import Data.Aeson.BetterErrors as AB
import Data.Aeson.Casing
import Data.Text hiding (head, tail, find, map, filter)
import Data.Text.Encoding
import GHC.Generics (Generic)
import Data.Maybe
import Waziup.Types
import qualified Data.HashMap.Strict as H
import Debug.Trace
import Control.Monad.Reader
import Data.Aeson.BetterErrors.Internal
import Data.Time.ISO8601
import Data.Foldable as F
import qualified Data.Vector as V
import Data.Scientific
import Network.HTTP.Client (HttpException)
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Lazy as L
import Data.Monoid
import Control.Monad.Except (ExceptT, throwError)
import Orion.Types
import Control.Exception


getSensorsOrion :: Orion [Sensor]
getSensorsOrion = do
  ents <- orionGet "/v2/entities?type=SensingDevice" (eachInArray parseEntity)
  return $ map getSensor ents

getSensorOrion :: EntityId -> Orion Sensor
getSensorOrion id = do
  ent <- orionGet ("/v2/entities/" <> id) parseEntity
  return $ getSensor ent

postSensorOrion :: Sensor -> Orion ()
postSensorOrion s = do
  liftIO $ putStrLn $ "Create sensor in Orion: " ++ (show $ encode s)
  let entity = getEntity s
  liftIO $ putStrLn $ "Entity: " ++ (show $ encode entity)
  orionOpts@(OrionConfig url _ _ _) <- ask 
  res <- liftIO $ postWith (getOptions orionOpts) (unpack url ++ "/v2/entities/") (toJSON entity)
  liftIO $ putStrLn $ "Created"
  return ()


-- * Generic Orion getter
orionGet :: Path -> Parse Text a -> Orion a 
orionGet path parser = do
  orionOpts@(OrionConfig url _ _ _) <- ask 
  getRes <-  liftIO $ try $ getWith (getOptions orionOpts) (unpack $ url <> path)
  case getRes of 
    Right res -> do
      let res2 = fromJust $ res ^? responseBody
      case AB.parse parser res2 of
         Right es -> return es
         Left err -> throwError $ ParseError $ pack (show err)
    Left err -> throwError $ HTTPError err

-- * Helper functions

getSensor :: Entity -> Sensor
getSensor (Entity eId etype attrs) = Sensor { senId           = eId,
                                              senGatewayId    = getSimpleAttribute "gateway_id" attrs,
                                              senName         = getSimpleAttribute "name" attrs,
                                              senOwner        = getSimpleAttribute "owner" attrs,
                                              senLocation     = getLocation attrs,
                                              senDomain       = getSimpleAttribute "domain" attrs,
                                              senVisibility   = getSimpleAttribute "visibility" attrs >>= readVisibility,
                                              senDateCreated  = getSimpleAttribute "dateCreated" attrs >>= parseISO8601.unpack,
                                              senDateUpdated  = getSimpleAttribute "dateModified" attrs >>= parseISO8601.unpack,
                                              senMeasurements = getMeasurements attrs,
                                              senKeycloakId   = getSimpleAttribute "keycloak_id" attrs}
                         
getSimpleAttribute :: Text -> [(Text, Attribute)] -> Maybe Text
getSimpleAttribute attName attrs = do
   (Attribute _ mval _) <- lookup attName attrs
   val <- mval
   getString val

getMeasurements :: [(Text, Attribute)] -> [Measurement]
getMeasurements attrs = mapMaybe getMeas attrs where 
  getMeas (name, Attribute aType val mets) = if (aType == "Measurement") 
     then Just $ Measurement { measId            = name,
                               measName          = getSimpleMetadata "name" mets,
                               measQuantityKind  = getSimpleMetadata "quantity_kind" mets,
                               measSensingDevice = getSimpleMetadata "sensing_device" mets,
                               measUnit          = getSimpleMetadata "unit" mets,
                               measLastValue     = getMeasLastValue val mets}
     else Nothing


getLocation :: [(Text, Attribute)] -> Maybe Location
getLocation attrs = do 
    (Attribute _ mval _) <- lookup "location" attrs
    (Object o) <- mval
    (Array a) <- lookup "coordinates" $ H.toList o
    let [Number lat, Number lon] = V.toList a
    return $ Location (toRealFloat lat) (toRealFloat lon)
 
getSimpleMetadata :: Text -> [(Text, Metadata)] -> Maybe Text
getSimpleMetadata name mets = do
   (Metadata _ mval) <- lookup name mets
   val <- mval
   getString val

getString :: Value -> Maybe Text
getString (String s) = Just s
getString _ = Nothing

getMeasLastValue :: Maybe Value -> [(Text, Metadata)] -> Maybe MeasurementValue
getMeasLastValue mval mets = do
   value <- mval
   return $ MeasurementValue value 
                             (getSimpleMetadata "timestamp" mets    >>= parseISO8601.unpack)
                             (getSimpleMetadata "dateModified" mets >>= parseISO8601.unpack)



getEntity :: Sensor -> Entity
getEntity (Sensor sid sgid sname sown meas sloc sdom _ _ svis _) = 
  Entity sid "SensingDevice" $ catMaybes [getSimpleAttr "name" sname,
                              getSimpleAttr "gateway_id" sgid,
                              getSimpleAttr "owner" sown,
                              getSimpleAttr "domain" sown,
                              getSimpleAttr "visibility" ((pack.show) <$> svis),
                              getLocationAttr sloc] 

getSimpleAttr :: Text -> Maybe Text -> Maybe (Text, Attribute)
getSimpleAttr name (Just val) = Just (name, Attribute "String" (Just $ toJSON val) [])
getSimpleAttr _ Nothing = Nothing

getLocationAttr :: Maybe Location -> Maybe (Text, Attribute)
getLocationAttr (Just (Location lat lon)) = Just ("location", Attribute "geo:json" (Just $ object ["type" .= ("Point" :: Text), "coordinates" .= [lon, lat]]) [])
getLocationAttr Nothing = Nothing
