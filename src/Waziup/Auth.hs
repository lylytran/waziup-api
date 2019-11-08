{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Waziup.Auth where

import           Waziup.Types as W
import           Waziup.Utils as U
import           Control.Monad.Except (throwError)
import           Control.Monad.IO.Class
import           Control.Monad
import           Data.Maybe
import           Data.Map as M hiding (map, mapMaybe, filter, delete)
import           Data.Time
import           Servant
import           Keycloak as KC hiding (info, warn, debug, err, try) 
import           System.Log.Logger
import           Control.Lens
import           Control.Concurrent.STM

-- | get a token
postAuth :: AuthBody -> Waziup Token
postAuth (AuthBody username password) = do
  info "Post authentication"
  tok <- liftKeycloak' $ getUserAuthToken username password
  return tok

-- * Permissions

-- | Get all permissions. If no token is passed, the guest token will be used.
getPermsDevices :: Maybe Token -> Waziup [Perm]
getPermsDevices tok = do
  info "Get devices permissions"
  getPerms tok (getPermReq Nothing deviceScopes)

-- | Get all permissions. If no token is passed, the guest token will be used.
getPermsProjects :: Maybe Token -> Waziup [Perm]
getPermsProjects tok = do
  info "Get projects permissions"
  getPerms tok (getPermReq Nothing projectScopes)

-- | Get all permissions. If no token is passed, the guest token will be used.
getPermsGateways :: Maybe Token -> Waziup [Perm]
getPermsGateways tok = do
  info "Get gateways permissions"
  getPerms tok (getPermReq Nothing gatewayScopes)

-- | Throws error 403 if `perms` if there is no permission for the resource under the corresponding scope.
checkPermResource :: Maybe Token -> W.Scope -> W.PermResource -> Waziup ()
checkPermResource tok scp rid = do
  perms <- getPerms tok (getPermReq (Just rid) [scp])
  if isPermittedResource scp rid perms 
    then return ()
    else throwError err403 {errBody = "Forbidden: Cannot access resource"}

-- | Check that `perms` contain a permission for the resource with the corresponding scope.
isPermittedResource :: W.Scope -> W.PermResource -> [Perm] -> Bool
isPermittedResource scp rid perms = any isPermitted perms where
  isPermitted :: Perm -> Bool
  isPermitted (Perm (Just rid') scopes) = rid == rid' && scp `elem` scopes
  isPermitted (Perm Nothing scopes) = scp `elem` scopes

getPermReq :: Maybe PermResource -> [W.Scope] -> PermReq
getPermReq pr scopes = PermReq (getKCResourceId <$> pr) (map fromScope scopes)

getPerms :: Maybe Token -> PermReq -> Waziup [Perm]
getPerms tok permReq = do
  let username = case tok of
       Just t -> getUsername t
       Nothing -> "guest"
  res <- getCachedPerms username permReq 
  case res of
    Just ps  -> return ps
    --No cached permission or outdated permission; getting from Keycloak and updating cache
    Nothing -> do
      res2 <- U.try $ liftKeycloak tok $ getPermissions [permReq]
      case res2 of
        Right kcPerms -> do
          let perms = map getPerm kcPerms
          writeCache username permReq perms 
          return perms 
        Left _ -> do 
          writeCache username permReq []
          return [] 

-- * Permission resources

createResource :: Maybe Token -> PermResource -> Maybe Visibility -> Maybe KC.Username -> Waziup ResourceId
createResource tok permRes vis muser = do
  --creating a new resource in Keycloak invalidates the cache
  invalidateCache permRes
  let (resTyp, scopes) = case permRes of
       PermDeviceId _  -> ("Device" , deviceScopes)
       PermGatewayId _ -> ("Gateway", gatewayScopes)
       PermProjectId _ -> ("Project", projectScopes)
  let attrs = if (isJust vis) then [KC.Attribute "visibility" [fromVisibility $ fromJust vis]] else []
  let username = case muser of
       Just user -> user          --if username is provided, use it. 
       Nothing -> case tok of
         Just t -> getUsername t  --Else, if token is provided, extract the username.
         Nothing -> "guest"       --Finally, use "guest" as a username.
  let kcres = KC.Resource {
         resId      = (Just $ getKCResourceId $ permRes),
         resName    = (unResId $ getKCResourceId $ permRes),
         resType    = Just resTyp,
         resUris    = [],
         resScopes  = map (\s -> KC.Scope Nothing (fromScope s)) scopes,
         resOwner   = Owner Nothing (Just username),
         resOwnerManagedAccess = True,
         resAttributes = attrs}
  liftKeycloak tok $ KC.createResource kcres

deleteResource :: Maybe Token -> PermResource -> Waziup ()
deleteResource _ pr = do
  --invalidate all cache
  invalidateCache pr
  --delete all resources
  void $ liftIO $ flip runKeycloak defaultKCConfig $ do
    tok2 <- KC.getClientAuthToken
    KC.deleteResource (getKCResourceId pr) tok2
  return ()

updateResource :: Maybe Token -> PermResource -> Maybe Visibility -> Maybe KC.Username -> Waziup ResourceId
updateResource = Waziup.Auth.createResource

--Cache management

getCachedPerms :: KC.Username -> PermReq -> Waziup (Maybe [Perm])
getCachedPerms username perm = do
  debug "getCachedPerms"
  permsTV <- view permCache
  permsM <- liftIO $ atomically $ readTVar permsTV
  now <- liftIO getCurrentTime
  --look up username in cache
  debug $ "lookup cache for " ++ (show username)
  case M.lookup (username, perm) permsM of
    Just (perms, retrievedTime) -> do
      debug "cache found"
      cacheDuration <- view (waziupConfig.serverConf.cacheValidDuration)
      --checl if not expired
      if now < addUTCTime cacheDuration retrievedTime
        --return permissions
        then do
          debug "cache valid"
          return $ Just perms
        --else get perms from Keycloak and update the cache
        else do
          debug "cache expired"
          return Nothing
    Nothing -> do
      debug $ "request not found in cache"
      return Nothing

writeCache :: KC.Username -> PermReq -> [Perm] -> Waziup ()
writeCache username permReq perms = do
  permsTV <- view permCache
  cache <- liftIO $ atomically $ readTVar permsTV
  now <- liftIO getCurrentTime
  debug "update cache"
  let cache' = cache & at (username, permReq) ?~ (perms, now)
  liftIO $ atomically $ writeTVar permsTV cache'
  return ()

-- invalidate cache on resource actions (create, update, delete)
invalidateCache :: PermResource -> Waziup ()
invalidateCache rid = do
  permsTV <- view permCache
  perms <- liftIO $ atomically $ readTVar permsTV
  let rid' = getKCResourceId rid
  let perms' = M.filterWithKey (\(_, req) _ -> isValidPermReq rid' req) perms
  liftIO $ atomically $ writeTVar permsTV perms'
  
-- filter perm reqs
isValidPermReq :: ResourceId -> PermReq -> Bool
isValidPermReq rid (PermReq (Just rid') _ )  = rid /= rid' -- Remove "resource" perm request
isValidPermReq _   (PermReq _           [])  = False       -- Remove "all scopes" perm requests
isValidPermReq _   (PermReq Nothing     _ )  = False       -- Remove "all resources" perm requests

-- Logging
warn, info, debug, err :: (MonadIO m) => String -> m ()
debug s = liftIO $ debugM   "Auth" s
info  s = liftIO $ infoM    "Auth" s
warn  s = liftIO $ warningM "Auth" s
err   s = liftIO $ errorM   "Auth" s

