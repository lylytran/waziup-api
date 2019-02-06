{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Waziup.Devices where

import           Waziup.Types as W
import           Waziup.Utils
import           Control.Monad.Except (throwError)
import           Control.Monad.IO.Class
import           Control.Monad.Catch as C
import           Control.Monad
import           Data.Maybe
import           Data.Text hiding (map, filter, foldl, any)
import           Data.String.Conversions
import qualified Data.List as L
import qualified Data.Vector as V
import           Data.Scientific
import qualified Data.HashMap.Strict as H
import           Data.Aeson as JSON hiding (Options)
import           Data.Time.ISO8601
import           Servant
import           Keycloak as KC hiding (info, warn, debug, err) 
import           Orion as O hiding (info, warn, debug, err)
import           System.Log.Logger
import           Paths_Waziup_Servant
import           Database.MongoDB as DB hiding (value, Limit, Array, lookup, Value, Null)
import           Data.AesonBson

getPerms :: Maybe Token -> Waziup [Perm]
getPerms tok = do
  info "Get Permissions"
  let allScopes = [DevicesUpdate,
                   DevicesView,
                   DevicesDelete,
                   DevicesDataCreate,
                   DevicesDataView]
  ps <- runKeycloak tok $ getAllPermissions (map (convertString.show) allScopes)
  let getP :: KC.Permission -> Perm
      getP (KC.Permission rsname _ scopes) = Perm rsname (mapMaybe readScope scopes)
  return $ map getP ps 

postAuth :: AuthBody -> Waziup Token
postAuth (AuthBody username password) = do
  info "Post authentication"
  tok <- runKeycloak' $ getUserAuthToken username password
  return tok

getDevices :: Maybe Token -> Maybe DevicesQuery -> Maybe Limit -> Maybe Offset -> Waziup [Device]
getDevices tok mq mlimit moffset = do
  info "Get devices"
  entities <- runOrion $ O.getEntities mq
  let devices = catMaybes $ map getDeviceFromEntity entities
  ps <- getPerms tok
  let devices2 = filter (checkPermDevice DevicesView ps . devId) devices -- TODO limits
  return devices2

checkPermDevice :: W.Scope -> [Perm] -> DeviceId -> Bool
checkPermDevice scope perms dev = any (\p -> (permResource p) == (unDeviceId $ dev) && scope `elem` (permScopes p)) perms

getDevice :: Maybe Token -> DeviceId -> Waziup Device
getDevice tok did = do
  info "Get device"
  withKCId did $ \(keyId, device) -> do
    debug "Check permissions"
    runKeycloak tok $ checkPermission keyId (pack $ show DevicesView)
    debug "Permission granted, returning device"
    return device

postDevice :: Maybe Token -> Device -> Waziup NoContent
postDevice tok d@(Device (DeviceId did) _ _ _ _ vis _ _ _ _ _ _) = do
  info $ "Post device: " ++ (show d)
  debug "Check permissions"
  runKeycloak tok $ checkPermission (ResourceId "Devices") (pack $ show DevicesCreate)
  debug "Create entity"
  let username = case tok of
       Just t -> getUsername t
       Nothing -> Just "guest"
  debug $ "Owner: " <> (show username)
  let entity = getEntityFromDevice (d {devOwner = username})
  res2 <- C.try $ runOrion $ O.postEntity entity 
  case res2 of
    Right _ -> do 
      let res = KC.Resource {
         resId      = Nothing,
         resName    = did,
         resType    = Nothing,
         resUris    = [],
         resScopes  = map (\s -> Scope Nothing (pack $ show s)) [DevicesView, DevicesUpdate, DevicesDelete, DevicesDataCreate, DevicesDataView],
         resOwner   = Owner Nothing "cdupont",
         resOwnerManagedAccess = True,
         resAttributes = if (isJust vis) then [KC.Attribute "visibility" [pack $ show $ fromJust vis]] else []}
      keyRes <- C.try $ runKeycloak tok $ createResource res
      case keyRes of
        Right (ResourceId resId) -> do
          runOrion $ O.postTextAttributeOrion (EntityId did) (AttributeId "keycloak_id") resId
          return NoContent
        Left e -> do
          err $ "Keycloak error: " ++ (show e) ++ " deleting device"
          (_ :: Either ServantErr ()) <- C.try $ runOrion $ O.deleteEntity (EntityId did)
          throwError e
    Left (err :: ServantErr)  -> do
      warn "Orion error"
      throwError err 
 
deleteDevice :: Maybe Token -> DeviceId -> Waziup NoContent
deleteDevice tok did = do
  info "Delete device"
  withKCId did $ \(keyId, _) -> do
    debug "Check permissions"
    runKeycloak tok $ checkPermission keyId (pack $ show DevicesDelete)
    debug "Delete Keycloak resource"
    runKeycloak tok $ deleteResource keyId
    debug "Delete Orion resource"
    runOrion $ O.deleteEntity (toEntityId did)
    debug "Delete Mongo resources"
    runMongo $ deleteDeviceDatapoints did
    return NoContent

putDeviceLocation :: Maybe Token -> DeviceId -> Location -> Waziup NoContent
putDeviceLocation mtok did loc = do
  info $ "Put device location: " ++ (show loc)
  withKCId did $ \(keyId, _) -> do
    debug "Check permissions"
    runKeycloak mtok $ checkPermission keyId (pack $ show DevicesUpdate)

    debug "Update Orion resource"
    let att = getLocationAttr loc
    runOrion $ O.postAttribute (toEntityId did) att 
  return NoContent

putDeviceName :: Maybe Token -> DeviceId -> DeviceName -> Waziup NoContent
putDeviceName mtok did name = do
  info $ "Put device name: " ++ (show name)
  withKCId did $ \(keyId, _) -> do
    debug "Check permissions"
    runKeycloak mtok $ checkPermission keyId (pack $ show DevicesUpdate)
    debug "Update Orion resource"
    runOrion $ O.postTextAttributeOrion (toEntityId did) (AttributeId "name") name
  return NoContent

putDeviceGatewayId :: Maybe Token -> DeviceId -> GatewayId -> Waziup NoContent
putDeviceGatewayId mtok did (GatewayId gid) = do
  info $ "Put device gateway ID: " ++ (show gid)
  withKCId did $ \(keyId, _) -> do
    debug "Check permissions"
    runKeycloak mtok $ checkPermission keyId (pack $ show DevicesUpdate)
    debug "Update Orion resource"
    runOrion $ O.postTextAttributeOrion (toEntityId did) (AttributeId "gateway_id") gid
  return NoContent

putDeviceVisibility :: Maybe Token -> DeviceId -> Visibility -> Waziup NoContent
putDeviceVisibility mtok did vis = do
  info $ "Put device visibility: " ++ (show vis)
  withKCId did $ \(keyId, _) -> do
    debug "Check permissions"
    runKeycloak mtok $ checkPermission keyId (pack $ show DevicesUpdate)
    debug "Update Orion resource"
    runOrion $ O.postTextAttributeOrion (toEntityId did) (AttributeId "visibility") (convertString $ show vis)
  return NoContent

-- * From Orion to Waziup types

getDeviceFromEntity :: O.Entity -> Maybe Device
getDeviceFromEntity (O.Entity (EntityId eId) eType attrs) = 
  if (eType == "Device") 
  then Just $ Device { devId           = DeviceId eId,
                       devGatewayId    = GatewayId <$> O.fromSimpleAttribute (AttributeId "gateway_id") attrs,
                       devName         = fromSimpleAttribute (AttributeId "name") attrs,
                       devOwner        = fromSimpleAttribute (AttributeId "owner") attrs,
                       devLocation     = getLocation attrs,
                       devDomain       = fromSimpleAttribute (AttributeId "domain") attrs,
                       devVisibility   = fromSimpleAttribute (AttributeId "visibility") attrs >>= readVisibility,
                       devDateCreated  = fromSimpleAttribute (AttributeId "dateCreated") attrs >>= parseISO8601.unpack,
                       devDateModified = fromSimpleAttribute (AttributeId "dateModified") attrs >>= parseISO8601.unpack,
                       devSensors      = mapMaybe getSensorFromAttribute attrs,
                       devActuators    = mapMaybe getActuatorFromAttribute attrs,
                       devKeycloakId   = ResourceId <$> O.fromSimpleAttribute (AttributeId "keycloak_id") attrs}
  else Nothing

getLocation :: [O.Attribute] -> Maybe Location
getLocation attrs = do 
    (O.Attribute _ _ mval _) <- L.find (\(O.Attribute attId _ _ _) -> attId == (AttributeId "location")) attrs
    (Object o) <- mval
    (Array a) <- lookup "coordinates" $ H.toList o
    let [Number lon, Number lat] = V.toList a
    return $ Location (Latitude $ toRealFloat lat) (Longitude $ toRealFloat lon)

getSensorFromAttribute :: O.Attribute -> Maybe Sensor
getSensorFromAttribute (O.Attribute (AttributeId name) aType val mets) =
  if (aType == "Sensor") 
    then Just $ Sensor { senId            = SensorId name,
                         senName          = fromSimpleMetadata (MetadataId "name") mets,
                         senQuantityKind  = QuantityKindId <$> fromSimpleMetadata (MetadataId "quantity_kind") mets,
                         senSensorKind    = SensorKindId   <$> fromSimpleMetadata (MetadataId "sensing_device") mets,
                         senUnit          = UnitId         <$> fromSimpleMetadata (MetadataId "unit") mets,
                         senValue         = getSensorValue val mets,
                         senCalib         = getSensorCalib mets}
    else Nothing

getActuatorFromAttribute :: O.Attribute -> Maybe Actuator
getActuatorFromAttribute (O.Attribute (AttributeId name) aType val mets) =
  if (aType == "Actuator") 
    then Just $ Actuator { actId                = ActuatorId name,
                           actName              = fromSimpleMetadata (MetadataId "name") mets,
                           actActuatorKind      = ActuatorKindId <$> fromSimpleMetadata (MetadataId "actuator_kind") mets,
                           actActuatorValueType = join $ readValueType  <$> fromSimpleMetadata (MetadataId "actuator_value_type") mets,
                           actValue             = val}
    else Nothing

getSensorValue :: Maybe Value -> [O.Metadata] -> Maybe SensorValue
getSensorValue mval mets = do
   value <- mval
   guard $ not $ isNull value
   return $ SensorValue value 
                        (O.fromSimpleMetadata (MetadataId "timestamp")    mets >>= parseISO8601.unpack)
                        (O.fromSimpleMetadata (MetadataId "dateModified") mets >>= parseISO8601.unpack)

getSensorCalib :: [O.Metadata] -> Maybe LinearCalib
getSensorCalib mets = do
   (Metadata _ _ mval) <- L.find (\(Metadata mid' _ _) -> mid' == (MetadataId "calib") ) mets
   val <- mval
   case fromJSON val of
     Success a -> Just a
     JSON.Error _ -> Nothing

isNull :: Value -> Bool
isNull Null = True
isNull _    = False


-- * From Waziup to Orion types

getEntityFromDevice :: Device -> O.Entity
getEntityFromDevice (Device (DeviceId sid) sgid sname sloc sdom svis sensors acts sown _ _ skey) = 
  O.Entity (EntityId sid) "Device" $ catMaybes [getSimpleAttr (AttributeId "name")        <$> sname,
                                                getSimpleAttr (AttributeId "gateway_id")  <$> (unGatewayId <$> sgid),
                                                getSimpleAttr (AttributeId "owner")       <$> sown,
                                                getSimpleAttr (AttributeId "domain")      <$> sdom,
                                                getSimpleAttr (AttributeId "keycloak_id") <$> (unResId <$> skey),
                                                getSimpleAttr (AttributeId "visibility")  <$> ((pack.show) <$> svis),
                                                getLocationAttr               <$> sloc] <>
                                                map getAttFromSensor sensors <>
                                                map getAttFromActuator acts

getLocationAttr :: Location -> O.Attribute
getLocationAttr (Location (Latitude lat) (Longitude lon)) = O.Attribute (AttributeId "location") "geo:json" (Just $ object ["type" .= ("Point" :: Text), "coordinates" .= [lon, lat]]) []

getAttFromSensor :: Sensor -> O.Attribute
getAttFromSensor (Sensor (SensorId senId) name sd qk u lv cal) = 
  (O.Attribute (AttributeId senId) "Sensor"
                     (senValValue <$> lv)
                     (catMaybes [getTextMetadata (MetadataId "name")           <$> name,
                                 getTextMetadata (MetadataId "quantity_kind")  <$> unQuantityKindId <$> qk,
                                 getTextMetadata (MetadataId "sensing_device") <$> unSensorKindId <$> sd,
                                 getTextMetadata (MetadataId "unit")           <$> unUnitId <$> u,
                                 getTimeMetadata (MetadataId "timestamp")      <$> (join $ senValTimestamp <$> lv),
                                 if (isJust cal) then Just $ Metadata (MetadataId "calib") (Just "Calib") (toJSON <$> cal) else Nothing]))

getAttFromActuator :: Actuator -> O.Attribute
getAttFromActuator (Actuator (ActuatorId actId) name ak avt av) = 
  (O.Attribute (AttributeId actId) "Actuator"
                     av
                     (catMaybes [getTextMetadata (MetadataId "name")           <$> name,
                                 getTextMetadata (MetadataId "actuator_kind")  <$> unActuatorKindId <$> ak,
                                 getTextMetadata (MetadataId "actuator_value_type") <$> convertString.show <$> avt]))


withKCId :: DeviceId -> ((ResourceId, Device) -> Waziup a) -> Waziup a
withKCId (DeviceId did) f = do
  mdevice <- getDeviceFromEntity <$> runOrion (O.getEntity $ EntityId did)
  case mdevice of
    Just device -> do
      case (devKeycloakId device) of
        Just keyId -> f (keyId, device) 
        Nothing -> do
          error "Device: KC Id not present"
          throwError err500 {errBody = "Device: KC Id not present"}
    Nothing -> throwError err500 {errBody = "Device: wrong entity type"}

toEntityId :: DeviceId -> EntityId
toEntityId (DeviceId did) = EntityId did


-- * Mongo datapoints

postDatapoint :: Datapoint -> Action IO ()
postDatapoint d = do
  debug "Post datapoint to Mongo"
  let ob = case toJSON d of
       JSON.Object o -> o
       _ -> error "Wrong object format"
  res <- insert "waziup_history" (bsonify ob)
  return ()

postDatapointFromSensor :: DeviceId -> Sensor -> Action IO ()
postDatapointFromSensor did (Sensor sid _ _ _ _ (Just (SensorValue v t rt)) _) = postDatapoint $ Datapoint did sid v t rt
postDatapointFromSensor did _ = return ()

postDatapointsFromDevice :: Device -> Action IO ()
postDatapointsFromDevice (Device did _ _ _ _ _ ss _ _ _ _ _) = void $ forM ss $ postDatapointFromSensor did
postDatapointsFromDevice _ = return ()

deleteSensorDatapoints :: DeviceId -> SensorId -> Action IO ()
deleteSensorDatapoints (DeviceId did) (SensorId sid) = do
  debug "delete datapoints from Mongo"
  res <- delete $ select ["device_id" =: did, "sensor_id" := val sid] "waziup_history"
  return ()

deleteDeviceDatapoints :: DeviceId -> Action IO ()
deleteDeviceDatapoints (DeviceId did) = do
  debug "delete datapoints from Mongo"
  res <- delete $ select ["device_id" =: did] "waziup_history"
  return ()


-- Logging
warn, info, debug, err :: (MonadIO m) => String -> m ()
debug s = liftIO $ debugM   "Devices" s
info  s = liftIO $ infoM    "Devices" s
warn  s = liftIO $ warningM "Devices" s
err   s = liftIO $ errorM   "Devices" s

