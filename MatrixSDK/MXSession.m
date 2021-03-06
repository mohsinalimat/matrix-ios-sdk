/*
 Copyright 2014 OpenMarket Ltd
 
 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at
 
 http://www.apache.org/licenses/LICENSE-2.0
 
 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */

#import "MXSession.h"
#import "MatrixSDK.h"

#import "MXSessionEventListener.h"

#import "MXTools.h"
#import "MXHTTPClient.h"

#import "MXNoStore.h"
#import "MXMemoryStore.h"
#import "MXFileStore.h"

#import "MXAccountData.h"

#pragma mark - Constants definitions

const NSString *MatrixSDKVersion = @"0.6.13";
NSString *const kMXSessionStateDidChangeNotification = @"kMXSessionStateDidChangeNotification";
NSString *const kMXSessionNewRoomNotification = @"kMXSessionNewRoomNotification";
NSString *const kMXSessionWillLeaveRoomNotification = @"kMXSessionWillLeaveRoomNotification";
NSString *const kMXSessionDidLeaveRoomNotification = @"kMXSessionDidLeaveRoomNotification";
NSString *const kMXSessionDidSyncNotification = @"kMXSessionDidSyncNotification";
NSString *const kMXSessionInvitedRoomsDidChangeNotification = @"kMXSessionInvitedRoomsDidChangeNotification";
NSString *const kMXSessionNotificationRoomIdKey = @"roomId";
NSString *const kMXSessionNotificationEventKey = @"event";
NSString *const kMXSessionIgnoredUsersDidChangeNotification = @"kMXSessionIgnoredUsersDidChangeNotification";
NSString *const kMXSessionDidCorruptDataNotification = @"kMXSessionDidCorruptDataNotification";
NSString *const kMXSessionNoRoomTag = @"m.recent";  // Use the same value as matrix-react-sdk

/**
 Default timeouts used by the events streams.
 */
#define SERVER_TIMEOUT_MS 30000
#define CLIENT_TIMEOUT_MS 120000


// Block called when MSSession resume is complete
typedef void (^MXOnResumeDone)();

@interface MXSession ()
{
    /**
     Rooms data
     Each key is a room ID. Each value, the MXRoom instance.
     */
    NSMutableDictionary<NSString*, MXRoom*> *rooms;
    
    /**
     Users data
     Each key is a user ID. Each value, the MXUser instance.
     */
    NSMutableDictionary *users;
    
    /**
     Private one-to-one rooms data
     Each key is a user ID. Each value is an array of MXRoom instances (in chronological order).
     */
    NSMutableDictionary *oneToOneRooms;

    /**
     The current request of the event stream.
     */
    MXHTTPOperation *eventStreamRequest;

    /**
     The list of global events listeners (`MXSessionEventListener`).
     */
    NSMutableArray *globalEventListeners;

    /**
     The limit value to use when doing /sync requests.
     -1, the default value, let the homeserver use its default value.
     */
    NSInteger syncMessagesLimit;

    /** 
     The block to call when MSSession resume is complete.
     */
    MXOnResumeDone onResumeDone;
    
    /**
     The block to call when MSSession backgroundSync is successfully done.
     */
    MXOnBackgroundSyncDone onBackgroundSyncDone;
    
    /**
     The block to call when MSSession backgroundSync fails.
     */
    MXOnBackgroundSyncFail onBackgroundSyncFail;

    /**
     The maintained list of rooms where the user has a pending invitation.
     */
    NSMutableArray<MXRoom *> *invitedRooms;

    /**
     The account data.
     */
    MXAccountData *accountData;

    /**
     The rooms being peeked.
     */
    NSMutableArray<MXPeekingRoom *> *peekingRooms;
}
@end

@implementation MXSession
@synthesize matrixRestClient;

- (id)initWithMatrixRestClient:(MXRestClient*)mxRestClient
{
    self = [super init];
    if (self)
    {
        matrixRestClient = mxRestClient;
        rooms = [NSMutableDictionary dictionary];
        users = [NSMutableDictionary dictionary];
        oneToOneRooms = [NSMutableDictionary dictionary];
        globalEventListeners = [NSMutableArray array];
        syncMessagesLimit = -1;
        _notificationCenter = [[MXNotificationCenter alloc] initWithMatrixSession:self];
        accountData = [[MXAccountData alloc] init];
        peekingRooms = [NSMutableArray array];
        
        [self setState:MXSessionStateInitialised];
    }
    return self;
}

- (void)setState:(MXSessionState)state
{
    if (_state != state)
    {
        _state = state;
        
        NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
        [notificationCenter postNotificationName:kMXSessionStateDidChangeNotification object:self userInfo:nil];
    }
}

-(void)setStore:(id<MXStore>)store success:(void (^)())onStoreDataReady failure:(void (^)(NSError *))failure
{
    NSAssert(MXSessionStateInitialised == _state, @"Store can be set only just after initialisation");
    NSParameterAssert(store);

    _store = store;

    // Validate the permanent implementation
    if (_store.isPermanent)
    {
        // A permanent MXStore must implement these methods:
        NSParameterAssert([_store respondsToSelector:@selector(rooms)]);
        NSParameterAssert([_store respondsToSelector:@selector(storeStateForRoom:stateEvents:)]);
        NSParameterAssert([_store respondsToSelector:@selector(stateOfRoom:)]);
        NSParameterAssert([_store respondsToSelector:@selector(userDisplayname)]);
        NSParameterAssert([_store respondsToSelector:@selector(setUserDisplayname:)]);
        NSParameterAssert([_store respondsToSelector:@selector(userAvatarUrl)]);
        NSParameterAssert([_store respondsToSelector:@selector(setUserAvatarUrl:)]);
    }

    NSDate *startDate = [NSDate date];

    [_store openWithCredentials:matrixRestClient.credentials onComplete:^{

        // Sanity check: The session may be closed before the end of store opening.
        if (!matrixRestClient)
        {
            return;
        }

        // Can we start on data from the MXStore?
        if (_store.isPermanent && _store.eventStreamToken && 0 < _store.rooms.count)
        {
            // Mount data from the permanent store
            NSLog(@"[MXSession] Loading room state events to build MXRoom objects...");

            // Create the user's profile from the store
            _myUser = [[MXMyUser alloc] initWithUserId:matrixRestClient.credentials.userId andDisplayname:_store.userDisplayname andAvatarUrl:_store.userAvatarUrl andMatrixSession:self];
            // And store him as a common MXUser
            users[matrixRestClient.credentials.userId] = _myUser;

            // Load user account data
            [self handleAccountData:_store.userAccountData];

            // Create MXRooms from their states stored in the store
            NSDate *startDate2 = [NSDate date];
            for (NSString *roomId in _store.rooms)
            {
                @autoreleasepool
                {
                    NSArray *stateEvents = [_store stateOfRoom:roomId];
                    MXRoomAccountData *roomAccountData = [_store accountDataOfRoom:roomId];
                    [self createRoom:roomId withStateEvents:stateEvents andAccountData:roomAccountData notify:NO];
                }
            }

            NSLog(@"[MXSession] Built %lu MXRooms in %.0fms", (unsigned long)rooms.allKeys.count, [[NSDate date] timeIntervalSinceDate:startDate2] * 1000);

            NSLog(@"[MXSession] Total time to mount SDK data from MXStore: %.0fms", [[NSDate date] timeIntervalSinceDate:startDate] * 1000);

            [self setState:MXSessionStateStoreDataReady];

            // The SDK client can use this data
            onStoreDataReady();
        }
        else
        {
            NSLog(@"[MXSession] Total time to mount SDK data from MXStore: %.0fms", [[NSDate date] timeIntervalSinceDate:startDate] * 1000);
            
            [self setState:MXSessionStateStoreDataReady];
            
            // The SDK client can use this data
            onStoreDataReady();
        }

    } failure:^(NSError *error) {
        [self setState:MXSessionStateInitialised];

        if (failure)
        {
            failure(error);
        }
    }];
}

- (void)start:(void (^)())onServerSyncDone
      failure:(void (^)(NSError *error))failure
{
    [self startWithMessagesLimit:-1 onServerSyncDone:onServerSyncDone failure:failure];
}

- (void)startWithMessagesLimit:(NSUInteger)messagesLimit
              onServerSyncDone:(void (^)())onServerSyncDone
                       failure:(void (^)(NSError *error))failure
{
    if (nil == _store)
    {
        // The user did not set a MXStore, use MXNoStore as default
        MXNoStore *store = [[MXNoStore alloc] init];

        // Set the store before going further
        __weak typeof(self) weakSelf = self;

        [self setStore:store success:^{

            // Then, start again
            __strong __typeof(weakSelf)strongSelf = weakSelf;
            [strongSelf startWithMessagesLimit:messagesLimit onServerSyncDone:onServerSyncDone failure:failure];

        } failure:^(NSError *error) {
            
            __strong __typeof(weakSelf)strongSelf = weakSelf;
            [strongSelf setState:MXSessionStateInitialSyncFailed];
            failure(error);
            
        }];
        return;
    }

    [self setState:MXSessionStateSyncInProgress];

    // Store the passed limit to reuse it when initialSyncing per room
    syncMessagesLimit = messagesLimit;

    // Can we resume from data available in the cache
    if (_store.isPermanent && _store.eventStreamToken && 0 < _store.rooms.count)
    {
        // Resume the stream (presence will be retrieved during server sync)
        NSLog(@"[MXSession] Resuming the events stream from %@...", _store.eventStreamToken);
        NSDate *startDate2 = [NSDate date];
        [self resume:^{
            NSLog(@"[MXSession] Events stream resumed in %.0fms", [[NSDate date] timeIntervalSinceDate:startDate2] * 1000);
            onServerSyncDone();
        }];
    }
    else
    {
        // Get data from the home server
        // First of all, retrieve the user's profile information
        [matrixRestClient displayNameForUser:matrixRestClient.credentials.userId success:^(NSString *displayname) {

            [matrixRestClient avatarUrlForUser:matrixRestClient.credentials.userId success:^(NSString *avatarUrl) {

                // Create the user's profile
                _myUser = [[MXMyUser alloc] initWithUserId:matrixRestClient.credentials.userId andDisplayname:displayname andAvatarUrl:avatarUrl andMatrixSession:self];

                // And store him as a common MXUser
                users[matrixRestClient.credentials.userId] = _myUser;
                    
                // Initial server sync
                [self serverSyncWithServerTimeout:0 success:onServerSyncDone failure:^(NSError *error) {

                    [self setState:MXSessionStateInitialSyncFailed];
                    failure(error);

                } clientTimeout:CLIENT_TIMEOUT_MS setPresence:nil];

            } failure:^(NSError *error) {
                
                [self setState:MXSessionStateInitialSyncFailed];
                failure(error);
                
            }];
        } failure:^(NSError *error) {
            
            [self setState:MXSessionStateInitialSyncFailed];
            failure(error);
            
        }];
    }
}

- (void)pause
{
    NSLog(@"[MXSession] pause the event stream in state %tu", _state);
    
    if ((_state == MXSessionStateRunning) || (_state == MXSessionStateBackgroundSyncInProgress))
    {
        // reset the callback
        onResumeDone = nil;
        onBackgroundSyncDone = nil;
        onBackgroundSyncFail = nil;
        
        // Cancel the current request managing the event stream
        [eventStreamRequest cancel];
        eventStreamRequest = nil;

        for (MXPeekingRoom *peekingRoom in peekingRooms)
        {
            [peekingRoom pause];
        }

        [self setState:MXSessionStatePaused];
    }
}

- (void)resume:(void (^)())resumeDone
{
    // Check whether no request is already in progress
    if (!eventStreamRequest || (_state == MXSessionStateBackgroundSyncInProgress))
    {
        [self setState:MXSessionStateSyncInProgress];
        
        // Resume from the last known token
        onResumeDone = resumeDone;
        
        if (!eventStreamRequest)
        {
            // Relaunch live events stream (long polling)
            [self serverSyncWithServerTimeout:0 success:nil failure:nil clientTimeout:CLIENT_TIMEOUT_MS setPresence:nil];
        }
    }

    for (MXPeekingRoom *peekingRoom in peekingRooms)
    {
        [peekingRoom resume];
    }
}

- (void)backgroundSync:(unsigned int)timeout success:(MXOnBackgroundSyncDone)backgroundSyncDone failure:(MXOnBackgroundSyncFail)backgroundSyncfails
{
    // Check whether no request is already in progress
    if (!eventStreamRequest)
    {
        if (MXSessionStatePaused != _state)
        {
            NSLog(@"[MXSession] background Sync cannot be done in the current state %tu", _state);
            dispatch_async(dispatch_get_main_queue(), ^{
                backgroundSyncfails(nil);
            });
        }
        else
        {
            NSLog(@"[MXSession] start a background Sync");
            [self setState:MXSessionStateBackgroundSyncInProgress];
            
            // BackgroundSync from the latest known token
            onBackgroundSyncDone = backgroundSyncDone;
            onBackgroundSyncFail = backgroundSyncfails;

            [self serverSyncWithServerTimeout:0 success:nil failure:nil clientTimeout:timeout setPresence:@"offline"];
        }
    }
}

- (BOOL)reconnect
{
    if (eventStreamRequest)
    {
        NSLog(@"[MXSession] Reconnect starts");
        [eventStreamRequest cancel];
        eventStreamRequest = nil;
        
        // retrieve the available data asap
        // disable the long poll to get the available data asap
        [self serverSyncWithServerTimeout:0 success:nil failure:nil clientTimeout:10 setPresence:nil];
        
        return YES;
    }
    else
    {
        NSLog(@"[MXSession] Reconnect fails.");
    }
    
    return NO;
}

- (void)close
{
    // Cancel the current server request (if any)
    [eventStreamRequest cancel];
    eventStreamRequest = nil;

    // Flush the store
    if ([_store respondsToSelector:@selector(close)])
    {
        [_store close];
    }
    
    [self removeAllListeners];

    // Clean MXRooms
    for (MXRoom *room in rooms.allValues)
    {
        [room.liveTimeline removeAllListeners];
    }
    [rooms removeAllObjects];

    // Clean MXUsers
    for (MXUser *user in users.allValues)
    {
        [user removeAllListeners];
    }
    [users removeAllObjects];

    // Clean peeking rooms
    for (MXPeekingRoom *peekingRoom in peekingRooms)
    {
        [peekingRoom close];
    }
    [peekingRooms removeAllObjects];

    [oneToOneRooms removeAllObjects];

    // Clean notification center
    [_notificationCenter removeAllListeners];
    _notificationCenter = nil;

    // Stop calls
    if (_callManager)
    {
        [_callManager close];
        _callManager = nil;
    }

    _myUser = nil;
    matrixRestClient = nil;

    [self setState:MXSessionStateClosed];
}

#pragma mark - Server sync

- (void)serverSyncWithServerTimeout:(NSUInteger)serverTimeout
                      success:(void (^)())success
                      failure:(void (^)(NSError *error))failure
                      clientTimeout:(NSUInteger)clientTimeout
                        setPresence:(NSString*)setPresence
{
    NSDate *startDate = [NSDate date];
    NSLog(@"[MXSession] Do a server sync");

    NSString *inlineFilter;
    if (-1 != syncMessagesLimit)
    {
        // If requested by the app, use a limit for /sync.
        inlineFilter = [NSString stringWithFormat:@"{\"room\":{\"timeline\":{\"limit\":%tu}}}", syncMessagesLimit];
    }

    eventStreamRequest = [matrixRestClient syncFromToken:_store.eventStreamToken serverTimeout:serverTimeout clientTimeout:clientTimeout setPresence:setPresence filter:inlineFilter success:^(MXSyncResponse *syncResponse) {
        
        // Make sure [MXSession close] or [MXSession pause] has not been called before the server response
        if (!eventStreamRequest)
        {
            return;
        }
        
        NSLog(@"[MXSession] Received %tu joined rooms, %tu invited rooms, %tu left rooms in %.0fms", syncResponse.rooms.join.count, syncResponse.rooms.invite.count, syncResponse.rooms.leave.count, [[NSDate date] timeIntervalSinceDate:startDate] * 1000);
        
        // Check whether this is the initial sync
        BOOL isInitialSync = !_store.eventStreamToken;
        
        // Handle first joined rooms
        for (NSString *roomId in syncResponse.rooms.join)
        {
            MXRoomSync *roomSync = syncResponse.rooms.join[roomId];
            
            @autoreleasepool {
                
                BOOL isOneToOneRoom = NO;
                
                // Retrieve existing room or create a new one
                MXRoom *room = [self roomWithRoomId:roomId];
                if (nil == room)
                {
                    room = [[MXRoom alloc] initWithRoomId:roomId andMatrixSession:self];
                    [self addRoom:room notify:!isInitialSync];
                }
                else
                {
                    isOneToOneRoom = (!room.state.isJoinRulePublic && room.state.members.count == 2);
                }
                
                // Sync room
                [room handleJoinedRoomSync:roomSync];

                if (isOneToOneRoom || (!room.state.isJoinRulePublic && room.state.members.count == 2))
                {
                    // Update one-to-one room dictionary
                    [self handleOneToOneRoom:room];
                }
                
            }
        }
        
        // Handle invited rooms
        for (NSString *roomId in syncResponse.rooms.invite)
        {
            MXInvitedRoomSync *invitedRoomSync = syncResponse.rooms.invite[roomId];
            
            @autoreleasepool {
                
                // Retrieve existing room or create a new one
                MXRoom *room = [self roomWithRoomId:roomId];
                if (nil == room)
                {
                    room = [[MXRoom alloc] initWithRoomId:roomId andMatrixSession:self];
                    [self addRoom:room notify:!isInitialSync];
                }
                
                // Prepare invited room
                [room handleInvitedRoomSync:invitedRoomSync];
                
            }
        }
        
        // Handle archived rooms
        for (NSString *roomId in syncResponse.rooms.leave)
        {
            MXRoomSync *leftRoomSync = syncResponse.rooms.leave[roomId];
            
            @autoreleasepool {
                
                // Presently we remove the existing room from the rooms list.
                // FIXME SYNCV2 Archive/Display the left rooms!
                // For that create 'handleArchivedRoomSync' method
                
                // Retrieve existing room
                MXRoom *room = [self roomWithRoomId:roomId];
                if (room)
                {
                    // FIXME SYNCV2: While 'handleArchivedRoomSync' is not available,
                    // use 'handleJoinedRoomSync' to pass the last events to the room before leaving it.
                    // The room will then able to notify its listeners.
                    [room handleJoinedRoomSync:leftRoomSync];

                    // Look for the last room member event
                    MXEvent *roomMemberEvent;
                    NSInteger index = leftRoomSync.timeline.events.count;
                    while (index--)
                    {
                        MXEvent *event = leftRoomSync.timeline.events[index];
                        
                        if ([event.type isEqualToString:kMXEventTypeStringRoomMember])
                        {
                            roomMemberEvent = event;
                            break;
                        }
                    }                    
                    
                    // Notify the room is going to disappear
                    NSMutableDictionary *userInfo = [NSMutableDictionary dictionaryWithObject:room.state.roomId forKey:kMXSessionNotificationRoomIdKey];
                    if (roomMemberEvent)
                    {
                        userInfo[kMXSessionNotificationEventKey] = roomMemberEvent;
                    }
                    [[NSNotificationCenter defaultCenter] postNotificationName:kMXSessionWillLeaveRoomNotification
                                                                        object:self
                                                                      userInfo:userInfo];
                    // Remove the room from the rooms list
                    [self removeRoom:room.state.roomId];
                }
            }
        }
        
        // Handle presence of other users
        for (MXEvent *presenceEvent in syncResponse.presence.events)
        {
            [self handlePresenceEvent:presenceEvent direction:MXTimelineDirectionForwards];
        }

        // Handle top-level account data
        if (syncResponse.accountData)
        {
            [self handleAccountData:syncResponse.accountData];
        }
        
        // Update live event stream token
        _store.eventStreamToken = syncResponse.nextBatch;
        
        // Commit store changes done in [room handleMessages]
        if ([_store respondsToSelector:@selector(commit)])
        {
            [_store commit];
        }
        
        // there is a pending backgroundSync
        if (onBackgroundSyncDone)
        {
            NSLog(@"[MXSession] Events stream background Sync succeeded");
            
            // Operations on session may occur during this block. For example, [MXSession close] may be triggered.
            // We run a copy of the block to prevent app from crashing if the block is released by one of these operations.
            MXOnBackgroundSyncDone onBackgroundSyncDoneCpy = [onBackgroundSyncDone copy];
            onBackgroundSyncDoneCpy();
            onBackgroundSyncDone = nil;
            
            // check that the application was not resumed while catching up in background
            if (_state == MXSessionStateBackgroundSyncInProgress)
            {
                NSLog(@"[MXSession] go to paused ");
                eventStreamRequest = nil;
                [self setState:MXSessionStatePaused];
                return;
            }
            else
            {
                NSLog(@"[MXSession] resume after a background Sync");
            }
        }
        
        // If we are resuming inform the app that it received the last uptodate data
        if (onResumeDone)
        {
            NSLog(@"[MXSession] Events stream resumed");
            
            // Operations on session may occur during this block. For example, [MXSession close] or [MXSession pause] may be triggered.
            // We run a copy of the block to prevent app from crashing if the block is released by one of these operations.
            MXOnResumeDone onResumeDoneCpy = [onResumeDone copy];
            onResumeDoneCpy();
            onResumeDone = nil;
            
            // Stop here if [MXSession close] or [MXSession pause] has been triggered during onResumeDone block.
            if (nil == _myUser || _state == MXSessionStatePaused)
            {
                return;
            }
        }
        
        // The event stream is running by now
        [self setState:MXSessionStateRunning];
        
        // Check SDK user did not called [MXSession close] or [MXSession pause] during the session state change notification handling.
        if (nil == _myUser || _state == MXSessionStatePaused)
        {
            return;
        }
        
        // Pursue live events listening (long polling)
        [self serverSyncWithServerTimeout:SERVER_TIMEOUT_MS success:nil failure:nil clientTimeout:CLIENT_TIMEOUT_MS setPresence:nil];
        
        // Broadcast that a server sync has been processed.
        [[NSNotificationCenter defaultCenter] postNotificationName:kMXSessionDidSyncNotification
                                                            object:self
                                                          userInfo:nil];
        
        if (success)
        {
            success();
        }
        
    } failure:^(NSError *error) {
        
        // Make sure [MXSession close] or [MXSession pause] has not been called before the server response
        if (!eventStreamRequest)
        {
            return;
        }

        if ([MXError isMXError:error])
        {
            // Detect invalidated access token
            // This can happen when the user made a forget password request for example
            MXError *mxError = [[MXError alloc] initWithNSError:error];
            if ([mxError.errcode isEqualToString:kMXErrCodeStringUnknownToken])
            {
                NSLog(@"[MXSession] The access token is no more valid. Go to MXSessionStateUnknownToken state. Error: %@", error);
                [self setState:MXSessionStateUnknownToken];

                // Do nothing more because without a valid access_token, the session is useless
                return;
            }
        }
        
        // Handle failure during catch up first
        if (onBackgroundSyncFail)
        {
            NSLog(@"[MXSession] background Sync fails %@", error);
            
            // Operations on session may occur during this block. For example, [MXSession close] may be triggered.
            // We run a copy of the block to prevent app from crashing if the block is released by one of these operations.
            MXOnBackgroundSyncFail onBackgroundSyncFailCpy = [onBackgroundSyncFail copy];
            onBackgroundSyncFailCpy(error);
            onBackgroundSyncFail = nil;
            
            // check that the application was not resumed while catching up in background
            if (_state == MXSessionStateBackgroundSyncInProgress)
            {
                NSLog(@"[MXSession] go to paused ");
                eventStreamRequest = nil;
                [self setState:MXSessionStatePaused];
                return;
            }
            else
            {
                NSLog(@"[MXSession] resume after a background Sync");
            }
        }
        
        // Check whether the caller wants to handle error himself
        if (failure)
        {
            failure(error);
        }
        else
        {
            // Handle error here
            // on 64 bits devices, the error codes are huge integers.
            int32_t code = (int32_t)error.code;
            
            if (code == kCFURLErrorCancelled)
            {
                NSLog(@"[MXSession] The connection has been cancelled.");
            }
            else if ((code == kCFURLErrorTimedOut) && serverTimeout == 0)
            {
                NSLog(@"[MXSession] The connection has been timeout.");
                // The reconnection attempt failed on timeout: there is no data to retrieve from server
                [eventStreamRequest cancel];
                eventStreamRequest = nil;
                
                // Notify the reconnection attempt has been done.
                [[NSNotificationCenter defaultCenter] postNotificationName:kMXSessionDidSyncNotification
                                                                    object:self
                                                                  userInfo:nil];
                
                // Switch back to the long poll management
                [self serverSyncWithServerTimeout:SERVER_TIMEOUT_MS success:nil failure:nil clientTimeout:CLIENT_TIMEOUT_MS setPresence:nil];
            }
            else
            {
                // Inform the app there is a problem with the connection to the homeserver
                [self setState:MXSessionStateHomeserverNotReachable];
                
                // Check if it is a network connectivity issue
                AFNetworkReachabilityManager *networkReachabilityManager = [AFNetworkReachabilityManager sharedManager];
                NSLog(@"[MXSession] events stream broken. Network reachability: %d", networkReachabilityManager.isReachable);
                
                if (networkReachabilityManager.isReachable)
                {
                    // The problem is not the network
                    // Relaunch the request in a random near futur.
                    // Random time it used to avoid all Matrix clients to retry all in the same time
                    // if there is server side issue like server restart
                    dispatch_time_t delayTime = dispatch_time(DISPATCH_TIME_NOW, [MXHTTPClient jitterTimeForRetry] * NSEC_PER_MSEC);
                    dispatch_after(delayTime, dispatch_get_main_queue(), ^(void) {
                        
                        if (eventStreamRequest)
                        {
                            NSLog(@"[MXSession] Retry resuming events stream");
                            [self setState:MXSessionStateSyncInProgress];
                            [self serverSyncWithServerTimeout:serverTimeout success:success failure:nil clientTimeout:CLIENT_TIMEOUT_MS setPresence:nil];
                        }
                    });
                }
                else
                {
                    // The device is not connected to the internet, wait for the connection to be up again before retrying
                    __block __weak id reachabilityObserver =
                    [[NSNotificationCenter defaultCenter] addObserverForName:AFNetworkingReachabilityDidChangeNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
                        
                        if (networkReachabilityManager.isReachable && eventStreamRequest)
                        {
                            [[NSNotificationCenter defaultCenter] removeObserver:reachabilityObserver];
                            
                            NSLog(@"[MXSession] Retry resuming events stream");
                            [self setState:MXSessionStateSyncInProgress];
                            [self serverSyncWithServerTimeout:serverTimeout success:success failure:nil clientTimeout:CLIENT_TIMEOUT_MS setPresence:nil];
                        }
                    }];
                }
            }
        }
    }];
}

- (void)handlePresenceEvent:(MXEvent *)event direction:(MXTimelineDirection)direction
{
    // Update MXUser with presence data
    NSString *userId = event.sender;
    if (userId)
    {
        MXUser *user = [self getOrCreateUser:userId];
        [user updateWithPresenceEvent:event];
    }

    [self notifyListeners:event direction:direction];
}

- (void)handleAccountData:(NSDictionary*)accountDataUpdate
{
    if (accountDataUpdate && accountDataUpdate[@"events"])
    {
        BOOL isInitialSync = !_store.eventStreamToken || _state == MXSessionStateInitialised;

        for (NSDictionary *event in accountDataUpdate[@"events"])
        {
            if ([event[@"type"] isEqualToString:kMXAccountDataPushRules])
            {
                // Handle push rules
                MXPushRulesResponse *pushRules = [MXPushRulesResponse modelFromJSON:event[@"content"]];

                if (![_notificationCenter.rules.JSONDictionary isEqualToDictionary:event[@"content"]])
                {
                    [_notificationCenter handlePushRulesResponse:pushRules];

                    // Report the change
                    if (!isInitialSync)
                    {
                        [[NSNotificationCenter defaultCenter] postNotificationName:kMXNotificationCenterDidUpdateRules
                                                                            object:_notificationCenter
                                                                          userInfo:nil];
                    }
                }
            }
            else if ([event[@"type"] isEqualToString:kMXAccountDataTypeIgnoredUserList])
            {
                // Handle the ignored users list
                NSArray *newIgnoredUsers = [event[@"content"][kMXAccountDataKeyIgnoredUser] allKeys];
                if (newIgnoredUsers)
                {
                    // Check the array changes whatever the order
                    NSCountedSet *set1 = [NSCountedSet setWithArray:_ignoredUsers];
                    NSCountedSet *set2 = [NSCountedSet setWithArray:newIgnoredUsers];

                    // Do not notify for the first /sync
                    BOOL notify = !isInitialSync && ![set1 isEqualToSet:set2];

                    _ignoredUsers = newIgnoredUsers;

                    // Report the change
                    if (notify)
                    {
                        [[NSNotificationCenter defaultCenter] postNotificationName:kMXSessionIgnoredUsersDidChangeNotification
                                                                            object:self
                                                                          userInfo:nil];
                    }
                }
            }

            // Update the corresponding part of account data
            [accountData updateWithEvent:event];
        }

        _store.userAccountData = accountData.accountData;
    }
}

#pragma mark - Options
- (void)enableVoIPWithCallStack:(id<MXCallStack>)callStack
{
    // A call stack is defined for life
    NSParameterAssert(!_callManager);

    _callManager = [[MXCallManager alloc] initWithMatrixSession:self andCallStack:callStack];
}


#pragma mark - Rooms operations

- (void)onCreatedRoom:(MXCreateRoomResponse*)response success:(void (^)(MXRoom *room))success
{
    // Wait to receive data from /sync about this room before returning
    if (success)
    {
        MXRoom *room = [self roomWithRoomId:response.roomId];
        if (room)
        {
            // The first /sync response for this room may have happened before the
            // homeserver answer to the createRoom request.
            success(room);
        }
        else
        {
            // Else, just wait for the corresponding kMXRoomInitialSyncNotification
            // that will be fired from MXRoom.
            __block id initialSyncObserver = [[NSNotificationCenter defaultCenter] addObserverForName:kMXRoomInitialSyncNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {

                MXRoom *room = note.object;

                if ([room.state.roomId isEqualToString:response.roomId])
                {
                    success(room);
                    [[NSNotificationCenter defaultCenter] removeObserver:initialSyncObserver];
                }
            }];
        }
    }
}

- (MXHTTPOperation*)createRoom:(NSString*)name
                    visibility:(MXRoomDirectoryVisibility)visibility
                     roomAlias:(NSString*)roomAlias
                         topic:(NSString*)topic
                       success:(void (^)(MXRoom *room))success
                       failure:(void (^)(NSError *error))failure
{
    return [matrixRestClient createRoom:name visibility:visibility roomAlias:roomAlias topic:topic success:^(MXCreateRoomResponse *response) {

        [self onCreatedRoom:response success:success];

    } failure:failure];
}

- (MXHTTPOperation*)createRoom:(NSDictionary*)parameters
                       success:(void (^)(MXRoom *room))success
                       failure:(void (^)(NSError *error))failure
{
    return [matrixRestClient createRoom:parameters success:^(MXCreateRoomResponse *response) {

        [self onCreatedRoom:response success:success];

    } failure:failure];
}

- (void)onJoinedRoom:(NSString*)roomId success:(void (^)(MXRoom *room))success
{
    MXRoom *room = [self getOrCreateRoom:roomId notify:YES];

    // check if the room is in the invited rooms list
    if ([self removeInvitedRoom:room])
    {
        [[NSNotificationCenter defaultCenter] postNotificationName:kMXSessionInvitedRoomsDidChangeNotification
                                                            object:self
                                                          userInfo:@{
                                                                     kMXSessionNotificationRoomIdKey: room.state.roomId,
                                                                     }];
    }

    // Wait to receive data from /sync about this room before returning
    if (success)
    {
        if (room.state.membership == MXMembershipJoin)
        {
            // The /sync corresponding to this join fmay have happened before the
            // homeserver answer to the joinRoom request.
            success(room);
        }
        else
        {
            // Else, just wait for the corresponding kMXRoomInitialSyncNotification
            // that will be fired from MXRoom.
            __block id initialSyncObserver = [[NSNotificationCenter defaultCenter] addObserverForName:kMXRoomInitialSyncNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {

                MXRoom *syncedRoom = note.object;

                if (syncedRoom == room)
                {
                    success(room);
                    [[NSNotificationCenter defaultCenter] removeObserver:initialSyncObserver];
                }
            }];
        }
    }

}

- (MXHTTPOperation*)joinRoom:(NSString*)roomIdOrAlias
                     success:(void (^)(MXRoom *room))success
                     failure:(void (^)(NSError *error))failure
{
    return [matrixRestClient joinRoom:roomIdOrAlias success:^(NSString *theRoomId) {

        [self onJoinedRoom:theRoomId success:success];

    } failure:failure];
}

- (MXHTTPOperation*)joinRoom:(NSString*)roomIdOrAlias
                 withSignUrl:(NSString*)signUrl
                     success:(void (^)(MXRoom *room))success
                     failure:(void (^)(NSError *error))failure
{
    MXHTTPOperation *httpOperation;
    httpOperation = [matrixRestClient signUrl:signUrl success:^(NSDictionary *thirdPartySigned) {

        MXHTTPOperation *httpOperation2 = [matrixRestClient joinRoom:roomIdOrAlias withThirdPartySigned:thirdPartySigned success:^(NSString *theRoomId) {

            [self onJoinedRoom:theRoomId success:success];

        } failure:failure];

        // Transfer the new AFHTTPRequestOperation to the returned MXHTTPOperation
        // So that user has hand on it
        if (httpOperation)
        {
            httpOperation.operation = httpOperation2.operation;
        }

    } failure:failure];

    return httpOperation;
}

- (MXHTTPOperation*)leaveRoom:(NSString*)roomId
                      success:(void (^)())success
                      failure:(void (^)(NSError *error))failure
{
    return [matrixRestClient leaveRoom:roomId success:^{

        // Check the room has been removed before calling the success callback
        // This is automatically done when the homeserver sends the MXMembershipLeave event.
        if ([self roomWithRoomId:roomId])
        {
            // The room is stil here, wait for the MXMembershipLeave event
            __block __weak id observer = [[NSNotificationCenter defaultCenter] addObserverForName:kMXSessionDidLeaveRoomNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {

                if ([roomId isEqualToString:note.userInfo[kMXSessionNotificationRoomIdKey]])
                {
                    [[NSNotificationCenter defaultCenter] removeObserver:observer];
                    if (success)
                    {
                        success();
                    }
                }
            }];
        }
        else
        {
            if (success)
            {
                success();
            }
        }

    } failure:failure];
}


#pragma mark - The user's rooms
- (MXRoom *)roomWithRoomId:(NSString *)roomId
{
    // sanity check
    if (roomId)
    {
        return [rooms objectForKey:roomId];
    }
    else
    {
        return nil;
    }
}

- (MXRoom *)roomWithAlias:(NSString *)alias
{
    MXRoom *theRoom;

    if (alias)
    {
        for (MXRoom *room in rooms.allValues)
        {
            if (room.state.aliases && NSNotFound != [room.state.aliases indexOfObject:alias])
            {
                theRoom = room;
                break;
            }
        }
    }
    return theRoom;
}

- (NSArray *)rooms
{
    return [rooms allValues];
}

- (MXRoom *)privateOneToOneRoomWithUserId:(NSString*)userId
{
    NSArray *array = [[oneToOneRooms objectForKey:userId] copy];
    if (array.count)
    {
        // Update stored rooms before returning the first one.
        // Indeed a state event may be handled and notified to the SDK user before updating private one-to-one room list.
        for (MXRoom *room in array)
        {
            [self handleOneToOneRoom:room];
        }
        
        array = [oneToOneRooms objectForKey:userId];
        if (array.count)
        {
            return array.firstObject;
        }
    }
    return nil;
}

- (MXRoom *)getOrCreateRoom:(NSString *)roomId notify:(BOOL)notify
{
    MXRoom *room = [self roomWithRoomId:roomId];
    if (nil == room)
    {
        room = [self createRoom:roomId notify:notify];
    }
    return room;
}

- (MXRoom *)createRoom:(NSString *)roomId notify:(BOOL)notify
{
    MXRoom *room = [[MXRoom alloc] initWithRoomId:roomId andMatrixSession:self];
    
    [self addRoom:room notify:notify];
    return room;
}

- (MXRoom *)createRoom:(NSString *)roomId withStateEvents:(NSArray*)stateEvents andAccountData:(MXRoomAccountData*)theAccountData notify:(BOOL)notify
{
    MXRoom *room = [[MXRoom alloc] initWithRoomId:roomId andMatrixSession:self andStateEvents:stateEvents andAccountData:theAccountData];

    [self addRoom:room notify:notify];
    return room;
}

- (void)addRoom:(MXRoom*)room notify:(BOOL)notify
{
    // Register global listeners for this room
    for (MXSessionEventListener *listener in globalEventListeners)
    {
        [listener addRoomToSpy:room];
    }

    [rooms setObject:room forKey:room.state.roomId];
    
    // We store one-to-one room in a second dictionary to ease their reuse.
    if (!room.state.isJoinRulePublic && room.state.members.count == 2)
    {
        [self handleOneToOneRoom:room];
    }

    if (notify)
    {
        // Broadcast the new room available in the MXSession.rooms array
        [[NSNotificationCenter defaultCenter] postNotificationName:kMXSessionNewRoomNotification
                                                            object:self
                                                          userInfo:@{
                                                                     kMXSessionNotificationRoomIdKey: room.state.roomId
                                                                     }];
    }
}

- (void)removeRoom:(NSString *)roomId
{
    MXRoom *room = [self roomWithRoomId:roomId];

    if (room)
    {
        // Unregister global listeners for this room
        for (MXSessionEventListener *listener in globalEventListeners)
        {
            [listener removeSpiedRoom:room];
        }

        // Clean the store
        [_store deleteRoom:roomId];
        
        // Clean one-to-one room dictionary
        if (!room.state.isJoinRulePublic && room.state.members.count == 2)
        {
            [self removeOneToOneRoom:room];
        }

        // And remove the room from the list
        [rooms removeObjectForKey:roomId];

        // Broadcast the left room
        [[NSNotificationCenter defaultCenter] postNotificationName:kMXSessionDidLeaveRoomNotification
                                                            object:self
                                                          userInfo:@{
                                                                     kMXSessionNotificationRoomIdKey: roomId
                                                                     }];
    }
}

- (void)handleOneToOneRoom:(MXRoom*)room
{
    // Retrieve the one-to-one contact in members list.
    NSArray* roomMembers = room.state.members;
    MXRoomMember* oneToOneContact = nil;
    
    // Check whether the room is a one-to-one room.
    if (roomMembers.count == 2)
    {
        oneToOneContact = [roomMembers objectAtIndex:0];
        if ([oneToOneContact.userId isEqualToString:self.myUser.userId])
        {
            oneToOneContact = [roomMembers objectAtIndex:1];
        }
    }
    
    // Check the membership of this member (Indeed the room should be ignored if the member left it)
    if (oneToOneContact && oneToOneContact.membership != MXMembershipLeave && oneToOneContact.membership != MXMembershipBan)
    {
        // Retrieve the current one-to-one rooms related to this user.
        NSMutableArray *array = [oneToOneRooms objectForKey:oneToOneContact.userId];
        if (array)
        {
            // Add the room if it is not already present
            if ([array indexOfObject:room] == NSNotFound)
            {
                [array addObject:room];
            }
            
            if (array.count > 1)
            {
                // In case of mutiple rooms, order them by origin_server_ts
                [array sortUsingComparator:^NSComparisonResult(MXRoom *obj1, MXRoom *obj2) {
                    NSComparisonResult result = NSOrderedAscending;
                    if ([obj2 lastMessageWithTypeIn:nil].originServerTs > [obj1 lastMessageWithTypeIn:nil].originServerTs) {
                        result = NSOrderedDescending;
                    } else if ([obj2 lastMessageWithTypeIn:nil].originServerTs == [obj1 lastMessageWithTypeIn:nil].originServerTs) {
                        result = NSOrderedSame;
                    }
                    return result;
                }];
            }
        }
        else
        {
            array = [NSMutableArray arrayWithObject:room];
        }
        
        [oneToOneRooms setObject:array forKey:oneToOneContact.userId];
    }
    else
    {
        [self removeOneToOneRoom:room];
    }
}

- (void)removeOneToOneRoom:(MXRoom*)room
{
    // This method should be called when a member left, or when a new member joined the room.
    
    // Remove this room from one-to-one rooms for each member.
    NSArray* roomMembers = room.state.members;
    for (MXRoomMember *member in roomMembers)
    {
        if ([member.userId isEqualToString:self.myUser.userId] == NO)
        {
            NSMutableArray *array = [oneToOneRooms objectForKey:member.userId];
            if (array)
            {
                NSUInteger index = [array indexOfObject:room];
                if (index != NSNotFound)
                {
                    [array removeObjectAtIndex:index];
                    
                    if (array.count)
                    {
                        [oneToOneRooms setObject:array forKey:member.userId];
                    }
                    else
                    {
                        [oneToOneRooms removeObjectForKey:member.userId];
                    }
                }
            }
        }
    }
}


#pragma mark - Room peeking
- (void)peekInRoomWithRoomId:(NSString*)roomId
                     success:(void (^)(MXPeekingRoom *peekingRoom))success
                     failure:(void (^)(NSError *error))failure
{
    MXPeekingRoom *peekingRoom = [[MXPeekingRoom alloc] initWithRoomId:roomId andMatrixSession:self];
    [peekingRooms addObject:peekingRoom];

    [peekingRoom start:^{

        success(peekingRoom);

    } failure:^(NSError *error) {

        // The room is not peekable, release the object
        [peekingRooms removeObject:peekingRoom];
        [peekingRoom close];
        
        NSLog(@"[MXSession] The room is not peekable");

        failure(error);

    }];
}

- (void)stopPeeking:(MXPeekingRoom*)peekingRoom
{
    [peekingRooms removeObject:peekingRoom];
    [peekingRoom close];
}

#pragma mark - Matrix users
- (MXUser *)userWithUserId:(NSString *)userId
{
    return [users objectForKey:userId];
}

- (NSArray *)users
{
    return [users allValues];
}

- (MXUser *)getOrCreateUser:(NSString *)userId
{
    MXUser *user = [self userWithUserId:userId];
    
    if (nil == user)
    {
        user = [[MXUser alloc] initWithUserId:userId andMatrixSession:self];
        [users setObject:user forKey:userId];
    }
    return user;
}

- (BOOL)isUserIgnored:(NSString *)userId
{
    return _ignoredUsers && (NSNotFound != [_ignoredUsers indexOfObject:userId]);
}

- (MXHTTPOperation*)ignoreUsers:(NSArray<NSString*>*)userIds
                       success:(void (^)())success
                       failure:(void (^)(NSError *error))failure
{
    // Create the new account data subset for m.ignored_user_list
    // by adding userIds
    NSMutableDictionary *ignoredUsersDict = [NSMutableDictionary dictionary];
    for (NSString *userId in _ignoredUsers)
    {
        ignoredUsersDict[userId] = @{};
    }
    for (NSString *userId in userIds)
    {
        ignoredUsersDict[userId] = @{};
    }

    // And make the request
    NSDictionary *data = @{
                           kMXAccountDataKeyIgnoredUser: ignoredUsersDict
                           };
//    __weak __typeof(self)weakSelf = self;
    return [matrixRestClient setAccountData:data forType:kMXAccountDataTypeIgnoredUserList success:^{

//        __strong __typeof(weakSelf)strongSelf = weakSelf;

        // Update self.ignoredUsers right now
// Commented as it created race condition with /sync response handling
//        NSMutableArray *newIgnoredUsers = [NSMutableArray arrayWithArray:strongSelf->_ignoredUsers];
//        for (NSString *userId in userIds)
//        {
//            if (NSNotFound == [newIgnoredUsers indexOfObject:userId])
//            {
//                [newIgnoredUsers addObject:userId];
//            }
//        }
//        strongSelf->_ignoredUsers = newIgnoredUsers;

        if (success)
        {
            success();
        }

    } failure:failure];
}

- (MXHTTPOperation *)unIgnoreUsers:(NSArray<NSString *> *)userIds success:(void (^)())success failure:(void (^)(NSError *))failure
{
    // Create the new account data subset for m.ignored_user_list
    // by substracting userIds
    NSMutableDictionary *ignoredUsersDict = [NSMutableDictionary dictionary];
    for (NSString *userId in _ignoredUsers)
    {
        ignoredUsersDict[userId] = @{};
    }
    for (NSString *userId in userIds)
    {
        [ignoredUsersDict removeObjectForKey:userId];
    }

    // And make the request
    NSDictionary *data = @{
                           kMXAccountDataKeyIgnoredUser: ignoredUsersDict
                           };
//    __weak __typeof(self)weakSelf = self;
    return [matrixRestClient setAccountData:data forType:kMXAccountDataTypeIgnoredUserList success:^{

//        __strong __typeof(weakSelf)strongSelf = weakSelf;

        // Update self.ignoredUsers right now
// Commented as it created race condition with /sync response handling
//        NSMutableArray *newIgnoredUsers = [NSMutableArray arrayWithArray:strongSelf->_ignoredUsers];
//        for (NSString *userId in userIds)
//        {
//            [newIgnoredUsers removeObject:userId];
//        }
//        strongSelf->_ignoredUsers = newIgnoredUsers;

        if (success)
        {
            success();
        }

    } failure:failure];
}


#pragma mark - User's recents
- (NSArray<MXEvent*>*)recentsWithTypeIn:(NSArray<MXEventTypeString>*)types
{
    NSMutableArray *recents = [NSMutableArray arrayWithCapacity:rooms.count];
    for (MXRoom *room in rooms.allValues)
    {
        // All rooms should have a last message
        [recents addObject:[room lastMessageWithTypeIn:types]];
    }
    
    // Order them by origin_server_ts
    [recents sortUsingSelector:@selector(compareOriginServerTs:)];
    
    return recents;
}

- (NSArray<MXRoom*>*)sortRooms:(NSArray<MXRoom*>*)roomsToSort byLastMessageWithTypeIn:(NSArray<MXEventTypeString>*)types
{
    NSMutableArray<MXRoom*> *sortedRooms = [NSMutableArray arrayWithCapacity:roomsToSort.count];

    NSMutableArray<MXEvent*>  *sortedLastMessages = [NSMutableArray arrayWithCapacity:roomsToSort.count];
    NSMapTable<MXEvent*, MXRoom*> *roomsByLastMessages = [[NSMapTable alloc] initWithKeyOptions:NSPointerFunctionsObjectPointerPersonality valueOptions:NSPointerFunctionsObjectPointerPersonality capacity:roomsToSort.count];

    // Get all last messages
    for (MXRoom *room in roomsToSort)
    {
        MXEvent *lastRoomMessage = [room lastMessageWithTypeIn:types];
        [sortedLastMessages addObject:lastRoomMessage];

        [roomsByLastMessages setObject:room forKey:lastRoomMessage];
    }

    // Order them by origin_server_ts
    [sortedLastMessages sortUsingSelector:@selector(compareOriginServerTs:)];

    // Build the ordered room list
    for (MXEvent *lastRoomMessage in sortedLastMessages)
    {
        [sortedRooms addObject:[roomsByLastMessages objectForKey:lastRoomMessage]];
    }

    return sortedRooms;
}


#pragma mark - User's special rooms

- (BOOL)removeInvitedRoom:(MXRoom*)roomToRemove
{
    BOOL hasBeenFound = NO;
    
    // sanity check
    if (invitedRooms.count > 0)
    {
        hasBeenFound =  ([invitedRooms indexOfObject:roomToRemove] != NSNotFound);
        
        // if the room object is not found
        // check if there is a room with the same roomId
        // indeed, during the room initial sync, the room object is deleted to be created again.
        if (!hasBeenFound)
        {
            for(MXRoom* room in invitedRooms)
            {
                if ([room.state.roomId isEqualToString:roomToRemove.state.roomId])
                {
                    roomToRemove = room;
                    hasBeenFound = YES;
                    break;
                }
            }
        }
        
        if (hasBeenFound)
        {
            [invitedRooms removeObject:roomToRemove];
        }
    }
    
    return hasBeenFound;
}

- (NSArray<MXRoom *> *)invitedRooms
{
    if (nil == invitedRooms)
    {
        // On the first call, set up the invitation list and mechanism to update it
        invitedRooms = [NSMutableArray array];

        // Compute the current invitation list
        for (MXRoom *room in rooms.allValues)
        {
            if (room.state.membership == MXMembershipInvite)
            {
                [invitedRooms addObject:room];
            }
        }

        // Order them by origin_server_ts
        [invitedRooms sortUsingSelector:@selector(compareOriginServerTs:)];

        // Add a listener in order to update the app about invitation list change
        [self listenToEventsOfTypes:@[kMXEventTypeStringRoomMember] onEvent:^(MXEvent *event, MXTimelineDirection direction, id customObject) {

            // in some race conditions the oneself join event is received during the sync instead of MXTimelineDirectionSync
            //
            // standard case
            // 1 - send a join request
            // 2 - receive the join event in the live stream -> call this method
            // 3 - perform an initial sync when the join method call the success callback
            //
            // but, this case also happens
            // 1 - send a join request
            // 2 - perform an initial sync when the join method call the success callback
            // 3 - receive the join event in the live stream -> this method is not called because the event has already been stored in the step 2
            // so, we need to manage the sync direction
            if (MXTimelineDirectionForwards == direction)
            {
                BOOL notify = NO;
                MXRoomState *roomPrevState = (MXRoomState *)customObject;
                MXRoom *room = [self roomWithRoomId:event.roomId];

                if (room.state.membership == MXMembershipInvite)
                {
                    // check if the room is not yet in the list
                    // must be done in forward and sync direction
                    if ([invitedRooms indexOfObject:room] == NSNotFound)
                    {
                        // This is an invite event. Add the room to the invitation list
                        [invitedRooms addObject:room];
                        notify = YES;
                    }
                }
                else if (roomPrevState.membership == MXMembershipInvite)
                {
                    // An invitation was pending for this room. A new membership event means the
                    // user has accepted or rejected the invitation.
                    notify = [self removeInvitedRoom:room];
                }

                if (notify)
                {
                    [[NSNotificationCenter defaultCenter] postNotificationName:kMXSessionInvitedRoomsDidChangeNotification
                                                                        object:self
                                                                      userInfo:@{
                                                                                 kMXSessionNotificationRoomIdKey: event.roomId,
                                                                                 kMXSessionNotificationEventKey: event
                                                                                 }];
                }
            }
        }];
    }

    return invitedRooms;
}


#pragma mark - User's rooms tags
- (NSArray<MXRoom*>*)roomsWithTag:(NSString*)tag
{
    if (![tag isEqualToString:kMXSessionNoRoomTag])
    {
        // Get all room with the passed tag
        NSMutableArray *roomsWithTag = [NSMutableArray array];
        for (MXRoom *room in rooms.allValues)
        {
            if (room.accountData.tags[tag])
            {
                [roomsWithTag addObject:room];
            }
        }

        // Sort them according to their tag order
        [roomsWithTag sortUsingComparator:^NSComparisonResult(MXRoom *room1, MXRoom *room2) {
            return [self compareRoomsByTag:tag room1:room1 room2:room2];
        }];

        return roomsWithTag;
    }
    else
    {
        // List rooms with no tags
        NSMutableArray *roomsWithNoTag = [NSMutableArray array];
        for (MXRoom *room in rooms.allValues)
        {
            if (0 == room.accountData.tags.count)
            {
                [roomsWithNoTag addObject:room];
            }
        }
        return roomsWithNoTag;
    }
}

- (NSDictionary<NSString*, NSArray<MXRoom*>*>*)roomsByTags
{
    NSMutableDictionary<NSString*, NSMutableArray<MXRoom*>*> *roomsByTags = [NSMutableDictionary dictionary];

    NSMutableArray<MXRoom*> *roomsWithNoTag = [NSMutableArray array];

    // Sort all rooms according to their defined tags
    for (MXRoom *room in rooms.allValues)
    {
        if (0 < room.accountData.tags.count)
        {
            for (NSString *tagName in room.accountData.tags)
            {
                MXRoomTag *tag = room.accountData.tags[tagName];
                if (!roomsByTags[tag.name])
                {
                    roomsByTags[tag.name] = [NSMutableArray array];
                }
                [roomsByTags[tag.name] addObject:room];
            }
        }
        else
        {
            // Put room with no tags in the recent list
            [roomsWithNoTag addObject:room];
        }
    }

    // For each tag, sort rooms according to their tag order
    for (NSString *tag in roomsByTags)
    {
        [roomsByTags[tag] sortUsingComparator:^NSComparisonResult(MXRoom *room1, MXRoom *room2) {
            return [self compareRoomsByTag:tag room1:room1 room2:room2];
        }];
    }

    // roomsWithNoTag can now be added to the result dictionary
    roomsByTags[kMXSessionNoRoomTag] = roomsWithNoTag;

    return roomsByTags;
}

- (NSComparisonResult)compareRoomsByTag:(NSString*)tag room1:(MXRoom*)room1 room2:(MXRoom*)room2
{
    NSComparisonResult result = NSOrderedSame;

    MXRoomTag *tag1 = room1.accountData.tags[tag];
    MXRoomTag *tag2 = room2.accountData.tags[tag];

    if (tag1.order && tag2.order)
    {
        // Do a lexicographic comparison
        result = [tag1.order localizedCompare:tag2.order];
    }
    else if (tag1.order)
    {
        result = NSOrderedDescending;
    }
    else if (tag2.order)
    {
        result = NSOrderedAscending;
    }

    // In case of same order, order rooms by their last event
    if (NSOrderedSame == result)
    {
        result = [[room1 lastMessageWithTypeIn:nil] compareOriginServerTs:[room2 lastMessageWithTypeIn:nil]];
    }

    return result;
}

- (NSString*)tagOrderToBeAtIndex:(NSUInteger)index from:(NSUInteger)originIndex withTag:(NSString *)tag
{
    // Algo (and the [0.0, 1.0] assumption) inspired from matrix-react-sdk:
    // We sort rooms by the lexicographic ordering of the 'order' metadata on their tags.
    // For convenience, we calculate this for now a floating point number between 0.0 and 1.0.

    double orderA = 0.0; // by default we're next to the beginning of the list
    double orderB = 1.0; // by default we're next to the end of the list too

    NSArray<MXRoom*> *roomsWithTag = [self roomsWithTag:tag];
    if (roomsWithTag.count)
    {
        // when an object is moved down, the index must be incremented
        // because the object will be removed from the list to be inserted after its destination
        if ((originIndex != NSNotFound) && (originIndex < index))
        {
            index++;
        }
        
        if (index > 0)
        {
            // Bound max index to the array size
            NSUInteger prevIndex = (index < roomsWithTag.count) ? index : roomsWithTag.count;

            MXRoomTag *prevTag = roomsWithTag[prevIndex - 1].accountData.tags[tag];
            if (!prevTag.order)
            {
                NSLog(@"[MXSession] computeTagOrderForRoom: Previous room in sublist has no ordering metadata. This should never happen.");
            }
            else
            {
                if (prevTag.parsedOrder)
                {
                    orderA = [prevTag.parsedOrder doubleValue];
                }
            }
        }

        if (index <= roomsWithTag.count - 1)
        {
            MXRoomTag *nextTag = roomsWithTag[index ].accountData.tags[tag];
            if (!nextTag.order)
            {
                NSLog(@"[MXSession] computeTagOrderForRoom: Next room in sublist has no ordering metadata. This should never happen.");
            }
            else
            {
                if (nextTag.parsedOrder)
                {
                    orderB = [nextTag.parsedOrder doubleValue];
                }
            }
        }
    }

    double order = (orderA + orderB) / 2.0;

    NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
    [formatter setGroupingSeparator:@""];
    [formatter setDecimalSeparator:@"."];
    [formatter setMaximumFractionDigits:16];
    [formatter setMinimumFractionDigits:0];
    
    // remove trailing 0
    // in some cases, the order is 0.00000 ("%f" formatter");
    // with this method, it becomes "0".
    return [formatter stringFromNumber:[NSNumber numberWithDouble:order]];
}


#pragma mark - Global events listeners
- (id)listenToEvents:(MXOnSessionEvent)onEvent
{
    return [self listenToEventsOfTypes:nil onEvent:onEvent];
}

- (id)listenToEventsOfTypes:(NSArray*)types onEvent:(MXOnSessionEvent)onEvent
{
    MXSessionEventListener *listener = [[MXSessionEventListener alloc] initWithSender:self andEventTypes:types andListenerBlock:onEvent];
    
    // This listener must be listen to all existing rooms
    for (MXRoom *room in rooms.allValues)
    {
        [listener addRoomToSpy:room];
    }
    
    [globalEventListeners addObject:listener];
    
    return listener;
}

- (void)removeListener:(id)listenerId
{
    // Clean the MXSessionEventListener
    MXSessionEventListener *listener = (MXSessionEventListener *)listenerId;
    [listener removeAllSpiedRooms];
    
    // Before removing it
    [globalEventListeners removeObject:listener];
}

- (void)removeAllListeners
{
    // must be done before deleted the listeners to avoid
    // ollection <__NSArrayM: ....> was mutated while being enumerated.'
    NSArray* eventListeners = [globalEventListeners copy];
    
    for (MXSessionEventListener *listener in eventListeners)
    {
        [self removeListener:listener];
    }
}

- (void)notifyListeners:(MXEvent*)event direction:(MXTimelineDirection)direction
{
    // Notify all listeners
    // The SDK client may remove a listener while calling them by enumeration
    // So, use a copy of them
    NSArray *listeners = [globalEventListeners copy];

    for (MXEventListener *listener in listeners)
    {
        // And check the listener still exists before calling it
        if (NSNotFound != [globalEventListeners indexOfObject:listener])
        {
            [listener notify:event direction:direction andCustomObject:nil];
        }
    }
}

@end
