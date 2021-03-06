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
#import "MXTools.h"

@implementation MXTools

/**
 Mapping from MXEventTypeString to MXEventType
 */
+ (NSDictionary*)eventTypesMap
{
    static NSDictionary *inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        inst = @{
                 kMXEventTypeStringRoomName: [NSNumber numberWithUnsignedInteger:MXEventTypeRoomName],
                 kMXEventTypeStringRoomTopic: [NSNumber numberWithUnsignedInteger:MXEventTypeRoomTopic],
                 kMXEventTypeStringRoomAvatar: [NSNumber numberWithUnsignedInteger:MXEventTypeRoomAvatar],
                 kMXEventTypeStringRoomMember: [NSNumber numberWithUnsignedInteger:MXEventTypeRoomMember],
                 kMXEventTypeStringRoomCreate: [NSNumber numberWithUnsignedInteger:MXEventTypeRoomCreate],
                 kMXEventTypeStringRoomJoinRules: [NSNumber numberWithUnsignedInteger:MXEventTypeRoomJoinRules],
                 kMXEventTypeStringRoomPowerLevels: [NSNumber numberWithUnsignedInteger:MXEventTypeRoomPowerLevels],
                 kMXEventTypeStringRoomAliases: [NSNumber numberWithUnsignedInteger:MXEventTypeRoomAliases],
                 kMXEventTypeStringRoomCanonicalAlias: [NSNumber numberWithUnsignedInteger:MXEventTypeRoomCanonicalAlias],
                 kMXEventTypeStringRoomHistoryVisibility: [NSNumber numberWithUnsignedInteger:MXEventTypeRoomHistoryVisibility],
                 kMXEventTypeStringRoomGuestAccess: [NSNumber numberWithUnsignedInteger:MXEventTypeRoomGuestAccess],
                 kMXEventTypeStringRoomMessage: [NSNumber numberWithUnsignedInteger:MXEventTypeRoomMessage],
                 kMXEventTypeStringRoomMessageFeedback: [NSNumber numberWithUnsignedInteger:MXEventTypeRoomMessageFeedback],
                 kMXEventTypeStringRoomRedaction: [NSNumber numberWithUnsignedInteger:MXEventTypeRoomRedaction],
                 kMXEventTypeStringRoomThirdPartyInvite: [NSNumber numberWithUnsignedInteger:MXEventTypeRoomThirdPartyInvite],
                 kMXEventTypeStringRoomTag: [NSNumber numberWithUnsignedInteger:MXEventTypeRoomTag],
                 kMXEventTypeStringPresence: [NSNumber numberWithUnsignedInteger:MXEventTypePresence],
                 kMXEventTypeStringTypingNotification: [NSNumber numberWithUnsignedInteger:MXEventTypeTypingNotification],
                 kMXEventTypeStringCallInvite: [NSNumber numberWithUnsignedInteger:MXEventTypeCallInvite],
                 kMXEventTypeStringCallCandidates: [NSNumber numberWithUnsignedInteger:MXEventTypeCallCandidates],
                 kMXEventTypeStringCallAnswer: [NSNumber numberWithUnsignedInteger:MXEventTypeCallAnswer],
                 kMXEventTypeStringCallHangup: [NSNumber numberWithUnsignedInteger:MXEventTypeCallHangup],
                 kMXEventTypeStringReceipt: [NSNumber numberWithUnsignedInteger:MXEventTypeReceipt]
                 };
    });
    return inst;
}

+ (MXEventTypeString)eventTypeString:(MXEventType)eventType
{
    NSArray *matches = [[MXTools eventTypesMap] allKeysForObject:[NSNumber numberWithUnsignedInteger:eventType]];
    return [matches lastObject];
}

+ (MXEventType)eventType:(MXEventTypeString)eventTypeString
{
    MXEventType eventType = MXEventTypeCustom;

    NSNumber *number = [[MXTools eventTypesMap] objectForKey:eventTypeString];
    if (number)
    {
        eventType = [number unsignedIntegerValue];
    }
    return eventType;
}


+ (MXMembership)membership:(MXMembershipString)membershipString
{
    MXMembership membership = MXMembershipUnknown;
    
    if ([membershipString isEqualToString:kMXMembershipStringInvite])
    {
        membership = MXMembershipInvite;
    }
    else if ([membershipString isEqualToString:kMXMembershipStringJoin])
    {
        membership = MXMembershipJoin;
    }
    else if ([membershipString isEqualToString:kMXMembershipStringLeave])
    {
        membership = MXMembershipLeave;
    }
    else if ([membershipString isEqualToString:kMXMembershipStringBan])
    {
        membership = MXMembershipBan;
    }
    return membership;
}


+ (MXPresence)presence:(MXPresenceString)presenceString
{
    MXPresence presence = MXPresenceUnknown;
    
    // Convert presence string into enum value
    if ([presenceString isEqualToString:kMXPresenceOnline])
    {
        presence = MXPresenceOnline;
    }
    else if ([presenceString isEqualToString:kMXPresenceUnavailable])
    {
        presence = MXPresenceUnavailable;
    }
    else if ([presenceString isEqualToString:kMXPresenceOffline])
    {
        presence = MXPresenceOffline;
    }
    
    return presence;
}

+ (MXPresenceString)presenceString:(MXPresence)presence
{
    MXPresenceString presenceString;
    
    switch (presence)
    {
        case MXPresenceOnline:
            presenceString = kMXPresenceOnline;
            break;
            
        case MXPresenceUnavailable:
            presenceString = kMXPresenceUnavailable;
            break;
            
        case MXPresenceOffline:
            presenceString = kMXPresenceOffline;
            break;
            
        default:
            break;
    }
    
    return presenceString;
}

+ (NSString *)generateSecret
{
    return [[NSProcessInfo processInfo] globallyUniqueString];
}

+ (BOOL)isEmailAddress:(NSString *)inputString
{
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"^[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}$" options:NSRegularExpressionCaseInsensitive error:nil];
    
    return (nil != [regex firstMatchInString:inputString options:0 range:NSMakeRange(0, inputString.length)]);
}

+ (BOOL)isMatrixUserIdentifier:(NSString *)inputString
{
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"^@[A-Z0-9]+:[A-Z0-9.-]+\\.[A-Z]{2,}$" options:NSRegularExpressionCaseInsensitive error:nil];
    
    return (nil != [regex firstMatchInString:inputString options:0 range:NSMakeRange(0, inputString.length)]);
}

+ (BOOL)isMatrixRoomAlias:(NSString *)inputString
{
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"^#[A-Z0-9._%+-]+:[A-Z0-9.-]+\\.[A-Z]{2,}$" options:NSRegularExpressionCaseInsensitive error:nil];
    
    return (nil != [regex firstMatchInString:inputString options:0 range:NSMakeRange(0, inputString.length)]);
}

+ (BOOL)isMatrixRoomIdentifier:(NSString *)inputString
{
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"^![A-Z0-9]+:[A-Z0-9.-]+\\.[A-Z]{2,}$" options:NSRegularExpressionCaseInsensitive error:nil];
    
    return (nil != [regex firstMatchInString:inputString options:0 range:NSMakeRange(0, inputString.length)]);
}

+ (NSString*)stripNewlineCharacters:(NSString *)inputString
{
    return [inputString stringByReplacingOccurrencesOfString:@" *[\n\r]+[\n\r ]*" withString:@" " options:NSRegularExpressionSearch range:NSMakeRange(0, [inputString length])];
}

@end
