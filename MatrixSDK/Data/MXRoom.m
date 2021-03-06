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

#import "MXRoom.h"

#import "MXSession.h"
#import "MXTools.h"

#import "MXError.h"

NSString *const kMXRoomDidFlushDataNotification = @"kMXRoomDidFlushDataNotification";
NSString *const kMXRoomInitialSyncNotification = @"kMXRoomInitialSyncNotification";
NSString *const kMXRoomDidUpdateUnreadNotification = @"kMXRoomDidUpdateUnreadNotification";

@interface MXRoom ()
{
}
@end

@implementation MXRoom
@synthesize mxSession;

- (instancetype)init
{
    self = [super init];
    if (self)
    {
        _accountData = [[MXRoomAccountData alloc] init];

        _typingUsers = [NSArray array];
        
        _acknowledgableEventTypes = @[kMXEventTypeStringRoomName,
                                      kMXEventTypeStringRoomTopic,
                                      kMXEventTypeStringRoomAvatar,
                                      kMXEventTypeStringRoomMember,
                                      kMXEventTypeStringRoomCreate,
                                      kMXEventTypeStringRoomJoinRules,
                                      kMXEventTypeStringRoomPowerLevels,
                                      kMXEventTypeStringRoomAliases,
                                      kMXEventTypeStringRoomCanonicalAlias,
                                      kMXEventTypeStringRoomGuestAccess,
                                      kMXEventTypeStringRoomHistoryVisibility,
                                      kMXEventTypeStringRoomMessage,
                                      kMXEventTypeStringRoomMessageFeedback,
                                      kMXEventTypeStringRoomRedaction,
                                      kMXEventTypeStringRoomThirdPartyInvite,
                                      kMXEventTypeStringCallInvite,
                                      kMXEventTypeStringCallCandidates,
                                      kMXEventTypeStringCallAnswer,
                                      kMXEventTypeStringCallHangup
                                      ];
        
        _unreadEventTypes = @[kMXEventTypeStringRoomName,
                              kMXEventTypeStringRoomTopic,
                              kMXEventTypeStringRoomMessage,
                              kMXEventTypeStringCallInvite
                              ];
    }
    
    return self;
}

- (id)initWithRoomId:(NSString *)roomId andMatrixSession:(MXSession *)mxSession2
{
    // Let's the live MXEventTimeline use its default store.
    return [self initWithRoomId:roomId matrixSession:mxSession2 andStore:nil];
}

- (id)initWithRoomId:(NSString *)roomId andMatrixSession:(MXSession *)mxSession2 andStateEvents:(NSArray *)stateEvents andAccountData:(MXRoomAccountData*)accountData
{
    self = [self initWithRoomId:roomId andMatrixSession:mxSession2];
    if (self)
    {
        @autoreleasepool
        {
            [_liveTimeline initialiseState:stateEvents];

            // Report the provided accountData.
            // Allocate a new instance if none, in order to handle room tag events for this room.
            _accountData = accountData ? accountData : [[MXRoomAccountData alloc] init];
        }
    }
    return self;
}

- (id)initWithRoomId:(NSString *)roomId matrixSession:(MXSession *)mxSession2 andStore:(id<MXStore>)store
{
    self = [self init];
    if (self)
    {
        _roomId = roomId;
        mxSession = mxSession2;

        if (store)
        {
            _liveTimeline = [[MXEventTimeline alloc] initWithRoom:self initialEventId:nil andStore:store];
        }
        else
        {
            // Let the timeline use the session store
            _liveTimeline = [[MXEventTimeline alloc] initWithRoom:self andInitialEventId:nil];
        }
    }
    return self;
}

#pragma mark - Properties implementation
- (MXRoomState *)state
{
    return _liveTimeline.state;
}

- (void)setPartialTextMessage:(NSString *)partialTextMessage
{
    [mxSession.store storePartialTextMessageForRoom:self.state.roomId partialTextMessage:partialTextMessage];
    if ([mxSession.store respondsToSelector:@selector(commit)])
    {
        [mxSession.store commit];
    }
}

- (NSString *)partialTextMessage
{
    return [mxSession.store partialTextMessageOfRoom:self.state.roomId];
}


#pragma mark - Sync
- (void)handleJoinedRoomSync:(MXRoomSync *)roomSync
{
    // Let the live timeline handle live events
    [_liveTimeline handleJoinedRoomSync:roomSync];

    // Handle here ephemeral events (if any)
    for (MXEvent *event in roomSync.ephemeral.events)
    {
        // Report the room id in the event as it is skipped in /sync response
        event.roomId = self.state.roomId;

        // Handle first typing notifications
        if (event.eventType == MXEventTypeTypingNotification)
        {
            // Typing notifications events are not room messages nor room state events
            // They are just volatile information
            MXJSONModelSetArray(_typingUsers, event.content[@"user_ids"]);

            // Notify listeners
            [_liveTimeline notifyListeners:event direction:MXTimelineDirectionForwards];
        }
        else if (event.eventType == MXEventTypeReceipt)
        {
            [self handleReceiptEvent:event direction:MXTimelineDirectionForwards];
        }
    }
    
    // Store notification counts from unreadNotifications field in /sync response
    [mxSession.store storeNotificationCountOfRoom:self.state.roomId count:roomSync.unreadNotifications.notificationCount];
    [mxSession.store storeHighlightCountOfRoom:self.state.roomId count:roomSync.unreadNotifications.highlightCount];
    
    // Notify that unread counts have been sync'ed
    [[NSNotificationCenter defaultCenter] postNotificationName:kMXRoomDidUpdateUnreadNotification
                                                        object:self
                                                      userInfo:nil];

    // Handle account data events (if any)
    [self handleAccounDataEvents:roomSync.accountData.events direction:MXTimelineDirectionForwards];
}

- (void)handleInvitedRoomSync:(MXInvitedRoomSync *)invitedRoomSync
{
    // Let the live timeline handle live events
    [_liveTimeline handleInvitedRoomSync:invitedRoomSync];
}


#pragma mark - Room private account data handling
/**
 Handle private user data events.

 @param accounDataEvents the events to handle.
 @param direction the process direction: MXTimelineDirectionSync or MXTimelineDirectionForwards. MXTimelineDirectionBackwards is not applicable here.
 */
- (void)handleAccounDataEvents:(NSArray<MXEvent*>*)accounDataEvents direction:(MXTimelineDirection)direction
{
    for (MXEvent *event in accounDataEvents)
    {
        [_accountData handleEvent:event];

        // Update the store
        if ([mxSession.store respondsToSelector:@selector(storeAccountDataForRoom:userData:)])
        {
            [mxSession.store storeAccountDataForRoom:self.state.roomId userData:_accountData];
        }

        // And notify listeners
        [_liveTimeline notifyListeners:event direction:direction];
    }
}


#pragma mark - Stored messages enumerator
- (id<MXEventsEnumerator>)enumeratorForStoredMessages
{
    return [mxSession.store messagesEnumeratorForRoom:self.roomId];
}

- (id<MXEventsEnumerator>)enumeratorForStoredMessagesWithTypeIn:(NSArray *)types ignoreMemberProfileChanges:(BOOL)ignoreProfileChanges
{
    return [mxSession.store messagesEnumeratorForRoom:self.roomId withTypeIn:types ignoreMemberProfileChanges:mxSession.ignoreProfileChangesDuringLastMessageProcessing];
}

- (MXEvent *)lastMessageWithTypeIn:(NSArray*)types
{
    id<MXEventsEnumerator> messagesEnumerator = [mxSession.store messagesEnumeratorForRoom:self.roomId withTypeIn:types ignoreMemberProfileChanges:mxSession.ignoreProfileChangesDuringLastMessageProcessing];
    MXEvent *lastMessage = messagesEnumerator.nextEvent;

    if (!lastMessage)
    {
        // If no messages match the filter contraints, return the last whatever is its type
        lastMessage = self.enumeratorForStoredMessages.nextEvent;
    }
    
    return lastMessage;
}

- (NSUInteger)storedMessagesCount
{
    // Note: For performance, it may worth to have a dedicated MXStore method to get
    // this value
    return self.enumeratorForStoredMessages.remaining;
}


#pragma mark - Room operations
- (MXHTTPOperation*)sendEventOfType:(MXEventTypeString)eventTypeString
                            content:(NSDictionary*)content
                            success:(void (^)(NSString *eventId))success
                            failure:(void (^)(NSError *error))failure
{
    return [mxSession.matrixRestClient sendEventToRoom:self.state.roomId eventType:eventTypeString content:content success:success failure:failure];
}

- (MXHTTPOperation*)sendStateEventOfType:(MXEventTypeString)eventTypeString
                                 content:(NSDictionary*)content
                                 success:(void (^)(NSString *eventId))success
                                 failure:(void (^)(NSError *error))failure
{
    return [mxSession.matrixRestClient sendStateEventToRoom:self.state.roomId eventType:eventTypeString content:content success:success failure:failure];
}

- (MXHTTPOperation*)sendMessageOfType:(MXMessageType)msgType
                              content:(NSDictionary*)content
                              success:(void (^)(NSString *eventId))success
                              failure:(void (^)(NSError *error))failure
{
    return [mxSession.matrixRestClient sendMessageToRoom:self.state.roomId msgType:msgType content:content success:success failure:failure];
}

- (MXHTTPOperation*)sendTextMessage:(NSString*)text
                            success:(void (^)(NSString *eventId))success
                            failure:(void (^)(NSError *error))failure
{
    return [mxSession.matrixRestClient sendTextMessageToRoom:self.state.roomId text:text success:success failure:failure];
}

- (MXHTTPOperation*)setTopic:(NSString*)topic
                     success:(void (^)())success
                     failure:(void (^)(NSError *error))failure
{
    return [mxSession.matrixRestClient setRoomTopic:self.state.roomId topic:topic success:success failure:failure];
}

- (MXHTTPOperation*)setAvatar:(NSString*)avatar
                     success:(void (^)())success
                     failure:(void (^)(NSError *error))failure
{
    return [mxSession.matrixRestClient setRoomAvatar:self.state.roomId avatar:avatar success:success failure:failure];
}


- (MXHTTPOperation*)setName:(NSString*)name
                    success:(void (^)())success
                    failure:(void (^)(NSError *error))failure
{
    return [mxSession.matrixRestClient setRoomName:self.state.roomId name:name success:success failure:failure];
}

- (MXHTTPOperation *)setHistoryVisibility:(MXRoomHistoryVisibility)historyVisibility
                                  success:(void (^)())success
                                  failure:(void (^)(NSError *))failure
{
    return [mxSession.matrixRestClient setRoomHistoryVisibility:self.state.roomId historyVisibility:historyVisibility success:success failure:failure];
}

- (MXHTTPOperation*)setJoinRule:(MXRoomJoinRule)joinRule
                        success:(void (^)())success
                        failure:(void (^)(NSError *error))failure
{
    return [mxSession.matrixRestClient setRoomJoinRule:self.state.roomId joinRule:joinRule success:success failure:failure];
}

- (MXHTTPOperation*)setGuestAccess:(MXRoomGuestAccess)guestAccess
                           success:(void (^)())success
                           failure:(void (^)(NSError *error))failure
{
    return [mxSession.matrixRestClient setRoomGuestAccess:self.state.roomId guestAccess:guestAccess success:success failure:failure];
}

- (MXHTTPOperation*)setDirectoryVisibility:(MXRoomDirectoryVisibility)directoryVisibility
                                   success:(void (^)())success
                                   failure:(void (^)(NSError *error))failure
{
    return [mxSession.matrixRestClient setRoomDirectoryVisibility:self.state.roomId directoryVisibility:directoryVisibility success:success failure:failure];
}

- (MXHTTPOperation*)addAlias:(NSString *)roomAlias
                     success:(void (^)())success
                     failure:(void (^)(NSError *error))failure
{
    return [mxSession.matrixRestClient addRoomAlias:self.state.roomId alias:roomAlias success:success failure:failure];
}

- (MXHTTPOperation*)removeAlias:(NSString *)roomAlias
                     success:(void (^)())success
                     failure:(void (^)(NSError *error))failure
{
    return [mxSession.matrixRestClient removeRoomAlias:roomAlias success:success failure:failure];
}

- (MXHTTPOperation*)setCanonicalAlias:(NSString *)canonicalAlias
                              success:(void (^)())success
                              failure:(void (^)(NSError *error))failure
{
    return [mxSession.matrixRestClient setRoomCanonicalAlias:self.state.roomId canonicalAlias:canonicalAlias success:success failure:failure];
}

- (MXHTTPOperation*)directoryVisibility:(void (^)(MXRoomDirectoryVisibility directoryVisibility))success
                                failure:(void (^)(NSError *error))failure
{
    return [mxSession.matrixRestClient directoryVisibilityOfRoom:self.state.roomId success:success failure:failure];
}

- (MXHTTPOperation*)join:(void (^)())success
                 failure:(void (^)(NSError *error))failure
{
    return [mxSession joinRoom:self.state.roomId success:^(MXRoom *room) {
        success();
    } failure:failure];
}

- (MXHTTPOperation*)leave:(void (^)())success
                  failure:(void (^)(NSError *error))failure
{
    return [mxSession leaveRoom:self.state.roomId success:success failure:failure];
}

- (MXHTTPOperation*)inviteUser:(NSString*)userId
                       success:(void (^)())success
                       failure:(void (^)(NSError *error))failure
{
    return [mxSession.matrixRestClient inviteUser:userId toRoom:self.state.roomId success:success failure:failure];
}

- (MXHTTPOperation*)inviteUserByEmail:(NSString*)email
                              success:(void (^)())success
                              failure:(void (^)(NSError *error))failure
{
    return [mxSession.matrixRestClient inviteUserByEmail:email toRoom:self.state.roomId success:success failure:failure];
}

- (MXHTTPOperation*)kickUser:(NSString*)userId
                      reason:(NSString*)reason
                     success:(void (^)())success
                     failure:(void (^)(NSError *error))failure
{
    return [mxSession.matrixRestClient kickUser:userId fromRoom:self.state.roomId reason:reason success:success failure:failure];
}

- (MXHTTPOperation*)banUser:(NSString*)userId
                     reason:(NSString*)reason
                    success:(void (^)())success
                    failure:(void (^)(NSError *error))failure
{
    return [mxSession.matrixRestClient banUser:userId inRoom:self.state.roomId reason:reason success:success failure:failure];
}

- (MXHTTPOperation*)unbanUser:(NSString*)userId
                      success:(void (^)())success
                      failure:(void (^)(NSError *error))failure
{
    return [mxSession.matrixRestClient unbanUser:userId inRoom:self.state.roomId success:success failure:failure];
}

- (MXHTTPOperation*)setPowerLevelOfUserWithUserID:(NSString *)userId powerLevel:(NSInteger)powerLevel
                                          success:(void (^)())success
                                          failure:(void (^)(NSError *))failure
{
    // To set this new value, we have to take the current powerLevels content,
    // Update it with expected values and send it to the home server.
    NSMutableDictionary *newPowerLevelsEventContent = [NSMutableDictionary dictionaryWithDictionary:self.state.powerLevels.JSONDictionary];

    NSMutableDictionary *newPowerLevelsEventContentUsers = [NSMutableDictionary dictionaryWithDictionary:newPowerLevelsEventContent[@"users"]];
    newPowerLevelsEventContentUsers[userId] = [NSNumber numberWithInteger:powerLevel];

    newPowerLevelsEventContent[@"users"] = newPowerLevelsEventContentUsers;

    // Make the request to the HS
    return [self sendStateEventOfType:kMXEventTypeStringRoomPowerLevels content:newPowerLevelsEventContent success:^(NSString *eventId) {
        success();
    } failure:failure];
}

- (MXHTTPOperation*)sendTypingNotification:(BOOL)typing
                                   timeout:(NSUInteger)timeout
                                   success:(void (^)())success
                                   failure:(void (^)(NSError *error))failure
{
    return [mxSession.matrixRestClient sendTypingNotificationInRoom:self.state.roomId typing:typing timeout:timeout success:success failure:failure];
}

- (MXHTTPOperation*)redactEvent:(NSString*)eventId
                         reason:(NSString*)reason
                        success:(void (^)())success
                        failure:(void (^)(NSError *error))failure
{
    return [mxSession.matrixRestClient redactEvent:eventId inRoom:self.state.roomId reason:reason success:success failure:failure];
}

- (MXHTTPOperation *)reportEvent:(NSString *)eventId
                           score:(NSInteger)score
                          reason:(NSString *)reason
                         success:(void (^)())success
                         failure:(void (^)(NSError *))failure
{
    return [mxSession.matrixRestClient reportEvent:eventId inRoom:self.state.roomId score:score reason:reason success:success failure:failure];
}


#pragma mark - Events timeline
- (MXEventTimeline*)timelineOnEvent:(NSString*)eventId;
{
    return [[MXEventTimeline alloc] initWithRoom:self andInitialEventId:eventId];
}


#pragma mark - Outgoing events management
- (void)storeOutgoingMessage:(MXEvent*)outgoingMessage
{
    if ([mxSession.store respondsToSelector:@selector(storeOutgoingMessageForRoom:outgoingMessage:)]
        && [mxSession.store respondsToSelector:@selector(commit)])
    {
        [mxSession.store storeOutgoingMessageForRoom:self.state.roomId outgoingMessage:outgoingMessage];
        [mxSession.store commit];
    }
}

- (void)removeAllOutgoingMessages
{
    if ([mxSession.store respondsToSelector:@selector(removeAllOutgoingMessagesFromRoom:)]
        && [mxSession.store respondsToSelector:@selector(commit)])
    {
        [mxSession.store removeAllOutgoingMessagesFromRoom:self.state.roomId];
        [mxSession.store commit];
    }
}

- (void)removeOutgoingMessage:(NSString*)outgoingMessageEventId
{
    if ([mxSession.store respondsToSelector:@selector(removeOutgoingMessageFromRoom:outgoingMessage:)]
        && [mxSession.store respondsToSelector:@selector(commit)])
    {
        [mxSession.store removeOutgoingMessageFromRoom:self.state.roomId outgoingMessage:outgoingMessageEventId];
        [mxSession.store commit];
    }
}

- (void)updateOutgoingMessage:(NSString *)outgoingMessageEventId withOutgoingMessage:(MXEvent *)outgoingMessage
{
    // Do the update by removing the existing one and create a new one
    // Thus, `outgoingMessage` will go at the end of the outgoing messages list
    [self removeOutgoingMessage:outgoingMessageEventId];
    [self storeOutgoingMessage:outgoingMessage];
}

- (NSArray<MXEvent*>*)outgoingMessages
{
    if ([mxSession.store respondsToSelector:@selector(outgoingMessagesInRoom:)])
    {
        return [mxSession.store outgoingMessagesInRoom:self.state.roomId];
    }
    else
    {
        return nil;
    }
}


#pragma mark - Room tags operations
- (MXHTTPOperation*)addTag:(NSString*)tag
                 withOrder:(NSString*)order
                   success:(void (^)())success
                   failure:(void (^)(NSError *error))failure
{
    // _accountData.tags will be updated by the live streams
    return [mxSession.matrixRestClient addTag:tag withOrder:order toRoom:self.state.roomId success:success failure:failure];
}

- (MXHTTPOperation*)removeTag:(NSString*)tag
                      success:(void (^)())success
                      failure:(void (^)(NSError *error))failure
{
    // _accountData.tags will be updated by the live streams
    return [mxSession.matrixRestClient removeTag:tag fromRoom:self.state.roomId success:success failure:failure];
}

- (MXHTTPOperation*)replaceTag:(NSString*)oldTag
                         byTag:(NSString*)newTag
                     withOrder:(NSString*)newTagOrder
                       success:(void (^)())success
                       failure:(void (^)(NSError *error))failure
{
    MXHTTPOperation *operation;
    
    // remove tag
    if (oldTag && !newTag)
    {
        operation = [self removeTag:oldTag success:success failure:failure];
    }
    // define a tag or define a new order
    else if ((!oldTag && newTag) || [oldTag isEqualToString:newTag])
    {
        operation = [self addTag:newTag withOrder:newTagOrder success:success failure:failure];
    }
    else
    {
        // the tag is not the same
        // weird, but the tag must be removed and defined again
        // so combine remove and add tag operations
        operation = [self removeTag:oldTag success:^{
            
            MXHTTPOperation *addTagHttpOperation = [self addTag:newTag withOrder:newTagOrder success:success failure:failure];
            
            // Transfer the new AFHTTPRequestOperation to the returned MXHTTPOperation
            // So that user has hand on it
            operation.operation = addTagHttpOperation.operation;
            
        } failure:failure];
    }
    
    return operation;
}


#pragma mark - Voice over IP
- (void)placeCallWithVideo:(BOOL)video
                   success:(void (^)(MXCall *call))success
                   failure:(void (^)(NSError *error))failure
{
    if (mxSession.callManager)
    {
        [mxSession.callManager placeCallInRoom:self.state.roomId withVideo:video success:success failure:failure];
    }
    else if (failure)
    {
        failure(nil);
    }
}


#pragma mark - Read receipts management

- (BOOL)handleReceiptEvent:(MXEvent *)event direction:(MXTimelineDirection)direction
{
    BOOL managedEvents = false;
    
    NSArray* eventIds = [event.content allKeys];
    
    for(NSString* eventId in eventIds)
    {
        NSDictionary* eventDict = [event.content objectForKey:eventId];
        NSDictionary* readDict = [eventDict objectForKey:kMXEventTypeStringRead];
        
        if (readDict)
        {
            NSArray* userIds = [readDict allKeys];
            
            for(NSString* userId in userIds)
            {
                NSDictionary* params = [readDict objectForKey:userId];
                
                if ([params valueForKey:@"ts"])
                {
                    MXReceiptData* data = [[MXReceiptData alloc] init];
                    data.userId = userId;
                    data.eventId = eventId;
                    data.ts = ((NSNumber*)[params objectForKey:@"ts"]).longLongValue;
                    
                    managedEvents |= [mxSession.store storeReceipt:data inRoom:self.state.roomId];
                }
            }
        }
    }
    
    // warn only if the receipts are not duplicated ones.
    if (managedEvents)
    {
        // Notify listeners
        [_liveTimeline notifyListeners:event direction:direction];
    }
    
    return managedEvents;
}

- (BOOL)acknowledgeLatestEvent:(BOOL)sendReceipt;
{    
    id<MXEventsEnumerator> messagesEnumerator = [mxSession.store messagesEnumeratorForRoom:self.roomId withTypeIn:_acknowledgableEventTypes ignoreMemberProfileChanges:NO];

    // Acknowledge the lastest valid event
    MXEvent *event;
    while ((event = messagesEnumerator.nextEvent))
    {
        // Sanity check on event id: Do not send read receipt on event without id
        if (event.eventId && ([event.eventId hasPrefix:kMXRoomInviteStateEventIdPrefix] == NO))
        {
            MXReceiptData *data = [[MXReceiptData alloc] init];

            data.userId = mxSession.myUser.userId;
            data.eventId = event.eventId;
            data.ts = (uint64_t) ([[NSDate date] timeIntervalSince1970] * 1000);

            if ([mxSession.store storeReceipt:data inRoom:self.state.roomId])
            {
                if ([mxSession.store respondsToSelector:@selector(commit)])
                {
                    [mxSession.store commit];
                }

                if (sendReceipt)
                {
                    [mxSession.matrixRestClient sendReadReceipts:self.state.roomId eventId:event.eventId success:^(NSString *eventId) {

                    } failure:^(NSError *error) {

                    }];
                }
                
                return YES;
            }
        }
        
    }

    return NO;
}

- (BOOL)hasUnreadEvents
{
    // Check for unread events in store
    return [mxSession.store hasUnreadEvents:self.state.roomId withTypeIn:_unreadEventTypes];
}

- (NSUInteger)notificationCount
{
    return [mxSession.store notificationCountOfRoom:self.state.roomId];
}

- (NSUInteger)highlightCount
{
    return [mxSession.store highlightCountOfRoom:self.state.roomId];
}

- (NSArray*)getEventReceipts:(NSString*)eventId sorted:(BOOL)sort
{
    NSArray *receipts = [mxSession.store getEventReceipts:self.state.roomId eventId:eventId sorted:sort];
    
    // if some receipts are found
    if (receipts)
    {
        NSString* myUserId = mxSession.myUser.userId;
        NSMutableArray* res = [[NSMutableArray alloc] init];
        
        // Remove the oneself receipts
        for (MXReceiptData* data in receipts)
        {
            if (![data.userId isEqualToString:myUserId])
            {
                [res addObject:data];
            }
        }
        
        if (res.count > 0)
        {
            receipts = res;
        }
        else
        {
            receipts = nil;
        }
    }
    
    return receipts;
}


#pragma mark - Utils
- (NSComparisonResult)compareOriginServerTs:(MXRoom *)otherRoom
{
    return [[otherRoom lastMessageWithTypeIn:nil] compareOriginServerTs:[self lastMessageWithTypeIn:nil]];
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<MXRoom: %p> %@: %@ - %@", self, self.state.roomId, self.state.name, self.state.topic];
}

@end
