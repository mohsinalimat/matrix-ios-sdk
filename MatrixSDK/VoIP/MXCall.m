/*
 Copyright 2015 OpenMarket Ltd

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

#import "MXCall.h"

#import "MXSession.h"
#import "MXCallStackCall.h"

#pragma mark - Constants definitions
NSString *const kMXCallStateDidChange = @"kMXCallStateDidChange";

@interface MXCall ()
{
    /**
     The manager of this object.
     */
    MXCallManager *callManager;

    /**
     The call object managed by the call stack
     */
    id<MXCallStackCall> callStackCall;

    /**
     The invite received by the peer
     */
    MXCallInviteEventContent *callInviteEventContent;

    /**
     The date when the communication has been established.
     */
    NSDate *callConnectedDate;

    /**
     The total duration of the call. It is computed when the call ends.
     */
    NSUInteger totalCallDuration;

    /**
     Timer to expire an invite.
     */
    NSTimer *inviteExpirationTimer;

    /**
     A queue of gathered local ICE candidates waiting to be sent to the other peer.
     */
    NSMutableArray<NSDictionary*> *localICECandidates;

    /**
     Timer for sending local ICE candidates.
     */
    NSTimer *localIceGatheringTimer;
}

@end

@implementation MXCall

- (instancetype)initWithRoomId:(NSString *)roomId andCallManager:(MXCallManager *)theCallManager
{
    // For 1:1 call, use the room as the call signaling room
    return [self initWithRoomId:roomId callSignalingRoomId:roomId andCallManager:theCallManager];
}

- (instancetype)initWithRoomId:(NSString*)roomId callSignalingRoomId:(NSString*)callSignalingRoomId andCallManager:(MXCallManager*)theCallManager;
{
    self = [super init];
    if (self)
    {
        callManager = theCallManager;

        _room = [callManager.mxSession roomWithRoomId:roomId];
        _callSignalingRoom = [callManager.mxSession roomWithRoomId:callSignalingRoomId];

        _callId = [[NSUUID UUID] UUIDString];
        _callerId = callManager.mxSession.myUser.userId;

        _state = MXCallStateFledgling;

        // Consider we are using a conference call when there are more than 2 users
        _isConferenceCall = (2 < _room.state.joinedMembers.count);

        localICECandidates = [NSMutableArray array];

        callStackCall = [callManager.callStack createCall];
        if (nil == callStackCall)
        {
            NSLog(@"[MXCall] Error: Cannot create call. [MXCallStack createCall] returned nil.");
            return nil;
        }

        callStackCall.delegate = self;

        // Set up TURN/STUN servers
        if (callManager.turnServers)
        {
            [callStackCall addTURNServerUris:callManager.turnServers.uris
                                        withUsername:callManager.turnServers.username
                                            password:callManager.turnServers.password];
        }
        else
        {
            NSLog(@"[MXCall] No TURN server: using fallback STUN server: %@", callManager.fallbackSTUNServer);
            [callStackCall addTURNServerUris:@[callManager.fallbackSTUNServer] withUsername:nil password:nil];
        }
    }
    return self;
}

- (void)handleCallEvent:(MXEvent *)event
{
    switch (event.eventType)
    {
        case MXEventTypeCallInvite:
        {
            callInviteEventContent = [MXCallInviteEventContent modelFromJSON:event.content];

            if (NO == [event.sender isEqualToString:_callSignalingRoom.mxSession.myUser.userId])
            {
                // Incoming call

                _callId = callInviteEventContent.callId;
                _callerId = event.sender;
                _isIncoming = YES;

                // Store if it is voice or video call
                _isVideoCall = callInviteEventContent.isVideoCall;

                // Set up the default audio route
                callStackCall.audioToSpeaker = NO;
                
                [callStackCall startCapturingMediaWithVideo:self.isVideoCall success:^{
                    [callStackCall handleOffer:callInviteEventContent.offer.sdp];
                    [self setState:MXCallStateRinging reason:event];
                } failure:^(NSError *error) {
                    NSLog(@"[MXCall] startCapturingMediaWithVideo: ERROR: Couldn't start capturing. Error: %@", error);
                    [self didEncounterError:error];
                }];
            }
            else
            {
                // Outgoing call. This is the invite event we sent
            }

            // Start expiration timer
            inviteExpirationTimer = [[NSTimer alloc] initWithFireDate:[NSDate dateWithTimeIntervalSinceNow:callInviteEventContent.lifetime / 1000]
                                                              interval:0
                                                                target:self
                                                              selector:@selector(expireCallInvite)
                                                              userInfo:nil
                                                               repeats:NO];
            [[NSRunLoop mainRunLoop] addTimer:inviteExpirationTimer forMode:NSDefaultRunLoopMode];

            break;
        }

        case MXEventTypeCallAnswer:
        {
            // Listen to answer event only for call we are making, not receiving
            if (NO == _isIncoming)
            {
                // MXCall receives this event only when it placed a call
                MXCallAnswerEventContent *content = [MXCallAnswerEventContent modelFromJSON:event.content];

                // The peer accepted our outgoing call
                if (inviteExpirationTimer)
                {
                    [inviteExpirationTimer invalidate];
                    inviteExpirationTimer = nil;
                }

                // Let's the stack finalise the connection
                [callStackCall handleAnswer:content.answer.sdp success:^{

                    // Call is up
                    [self setState:MXCallStateConnected reason:event];

                } failure:^(NSError *error) {
                    NSLog(@"[MXCall] handleCallEvent: ERROR: Cannot send handle answer. Error: %@\nEvent: %@", error, event);
                    [self didEncounterError:error];
                }];
            }
            else if (_state == MXCallStateRinging)
            {
                // Else this event means that the call has been answered by the user from
                // another device
                [self onCallAnsweredElsewhere];
            }
            break;
        }

        case MXEventTypeCallHangup:
        {
            if (_state != MXCallStateEnded)
            {
                [self terminateWithReason:event];
            }
            break;
        }

        case MXEventTypeCallCandidates:
        {
            if (NO == [event.sender isEqualToString:_callSignalingRoom.mxSession.myUser.userId])
            {
                MXCallCandidatesEventContent *content = [MXCallCandidatesEventContent modelFromJSON:event.content];

                NSLog(@"[MXCall] handleCallCandidates: %@", content.candidates);
                for (MXCallCandidate *canditate in content.candidates)
                {
                    [callStackCall handleRemoteCandidate:canditate.JSONDictionary];
                }
            }
            break;
        }

        default:
            break;
    }
}


#pragma mark - Controls
- (void)callWithVideo:(BOOL)video
{
    NSLog(@"[MXCall] callWithVideo");
    
    _isIncoming = NO;

    _isVideoCall = video;

    [self setState:MXCallStateWaitLocalMedia reason:nil];

    // Set up the default audio route
    callStackCall.audioToSpeaker = NO;

    [callStackCall startCapturingMediaWithVideo:video success:^() {

        [callStackCall createOffer:^(NSString *sdp) {

            [self setState:MXCallStateCreateOffer reason:nil];

            NSLog(@"[MXCall] callWithVideo:%@ - Offer created: %@", (video ? @"YES" : @"NO"), sdp);

            // The call invite can sent to the HS
            NSDictionary *content = @{
                                      @"call_id": _callId,
                                      @"offer": @{
                                              @"type": @"offer",
                                              @"sdp": sdp
                                              },
                                      @"version": @(0),
                                      @"lifetime": @(callManager.inviteLifetime)
                                      };
            [_callSignalingRoom sendEventOfType:kMXEventTypeStringCallInvite content:content success:^(NSString *eventId) {

                [self setState:MXCallStateInviteSent reason:nil];

            } failure:^(NSError *error) {
                NSLog(@"[MXCall] callWithVideo: ERROR: Cannot send m.call.invite event. Error: %@", error);
                [self didEncounterError:error];
            }];

        } failure:^(NSError *error) {
            NSLog(@"[MXCall] callWithVideo: ERROR: Cannot create offer. Error: %@", error);
            [self didEncounterError:error];
        }];
    } failure:^(NSError *error) {
        NSLog(@"[MXCall] callWithVideo: ERROR: Cannot start capturing media. Error: %@", error);
        [self didEncounterError:error];
    }];
}

- (void)answer
{
    NSLog(@"[MXCall] answer");

    if (self.state == MXCallStateRinging)
    {
        // The incoming call is accepted
        if (inviteExpirationTimer)
        {
            [inviteExpirationTimer invalidate];
            inviteExpirationTimer = nil;
        }

        [self setState:MXCallStateWaitLocalMedia reason:nil];
        
        
        // Create a sdp answer from the offer we got
        [self setState:MXCallStateCreateAnswer reason:nil];
        [self setState:MXCallStateConnecting reason:nil];

        [callStackCall createAnswer:^(NSString *sdpAnswer) {

            NSLog(@"[MXCall] answer - Created SDP:\n%@", sdpAnswer);
            
            // The call invite can sent to the HS
            NSDictionary *content = @{
                                      @"call_id": _callId,
                                      @"answer": @{
                                              @"type": @"answer",
                                              @"sdp": sdpAnswer
                                              },
                                      @"version": @(0),
                                      };
            [_callSignalingRoom sendEventOfType:kMXEventTypeStringCallAnswer content:content success:^(NSString *eventId) {

                // @TODO: This is false
                [self setState:MXCallStateConnected reason:nil];
                
            } failure:^(NSError *error) {
                NSLog(@"[MXCall] answer: ERROR: Cannot send m.call.answer event. Error: %@", error);
                [self didEncounterError:error];
            }];
            
        } failure:^(NSError *error) {
            NSLog(@"[MXCall] answer: ERROR: Cannot create offer. Error: %@", error);
            [self didEncounterError:error];
        }];
        
        callInviteEventContent = nil;
    }
}

- (void)hangup
{
    NSLog(@"[MXCall] hangup");

    if (self.state != MXCallStateEnded)
    {
        [self terminateWithReason:nil];

        // Send the hangup event
        NSDictionary *content = @{
                                  @"call_id": _callId,
                                  @"version": @(0)
                                  };
        [_callSignalingRoom sendEventOfType:kMXEventTypeStringCallHangup content:content success:nil failure:^(NSError *error) {
            NSLog(@"[MXCall] hangup: ERROR: Cannot send m.call.hangup event. Error: %@", error);
            [self didEncounterError:error];
        }];
    }
}


#pragma marl - Properties
- (void)setState:(MXCallState)state reason:(MXEvent*)event
{
    // Manage call duration
    if (MXCallStateConnected == state)
    {
        // Set the start point
        callConnectedDate = [NSDate date];
    }
    else if (MXCallStateEnded == state)
    {
        // Store the total duration
        totalCallDuration = self.duration;
    }

    _state = state;

    if (_delegate)
    {
        [_delegate call:self stateDidChange:_state reason:event];
    }

    // Broadcast the new call state
    [[NSNotificationCenter defaultCenter] postNotificationName:kMXCallStateDidChange object:self userInfo:nil];
}

- (void)setSelfVideoView:(UIView *)selfVideoView
{
    if (selfVideoView != _selfVideoView)
    {
        _selfVideoView = selfVideoView;
        callStackCall.selfVideoView = selfVideoView;
    }
}

- (void)setRemoteVideoView:(UIView *)remoteVideoView
{
    if (remoteVideoView != _remoteVideoView)
    {
        _remoteVideoView = remoteVideoView;
        callStackCall.remoteVideoView = remoteVideoView;
    }
}

- (UIDeviceOrientation)selfOrientation
{
    return callStackCall.selfOrientation;
}

- (void)setSelfOrientation:(UIDeviceOrientation)selfOrientation
{
    if (callStackCall.selfOrientation != selfOrientation)
    {
        callStackCall.selfOrientation = selfOrientation;
    }
}

- (BOOL)audioMuted
{
    return callStackCall.audioMuted;
}

- (void)setAudioMuted:(BOOL)audioMuted
{
    callStackCall.audioMuted = audioMuted;
}

- (BOOL)videoMuted
{
    return callStackCall.videoMuted;
}

- (void)setVideoMuted:(BOOL)videoMuted
{
    callStackCall.videoMuted = videoMuted;
}

- (BOOL)audioToSpeaker
{
    return callStackCall.audioToSpeaker;
}

- (void)setAudioToSpeaker:(BOOL)audioToSpeaker
{
    callStackCall.audioToSpeaker = audioToSpeaker;
}

- (AVCaptureDevicePosition)cameraPosition
{
    return callStackCall.cameraPosition;
}

- (void)setCameraPosition:(AVCaptureDevicePosition)cameraPosition
{
    if (cameraPosition != callStackCall.cameraPosition)
    {
        callStackCall.cameraPosition = cameraPosition;
    }
}

- (NSUInteger)duration
{
    NSUInteger duration = 0;

    if (MXCallStateConnected == _state)
    {
        duration = [[NSDate date] timeIntervalSinceDate:callConnectedDate] * 1000;
    }
    else if (MXCallStateEnded == _state)
    {
        duration = totalCallDuration;
    }
    return duration;
}


#pragma mark - MXCallStackCallDelegate
- (void)callStackCall:(id<MXCallStackCall>)callStackCall onICECandidateWithSdpMid:(NSString *)sdpMid sdpMLineIndex:(NSInteger)sdpMLineIndex candidate:(NSString *)candidate
{
    // Candidates are sent in a special way because we try to amalgamate
    // them into one message
    // No need for locking data as everything is running on the main thread
    [localICECandidates addObject:@{
                                    @"sdpMid": sdpMid,
                                    @"sdpMLineIndex": @(sdpMLineIndex),
                                    @"candidate":candidate
                                    }
     ];

    // Send candidates every 100ms max. This value gives enough time to the underlaying call stack
    // to gather several ICE candidates
    [localIceGatheringTimer invalidate];
    localIceGatheringTimer = [NSTimer scheduledTimerWithTimeInterval:0.1 target:self selector:@selector(sendLocalIceCandidates) userInfo:self repeats:NO];
}

- (void)sendLocalIceCandidates
{
    localIceGatheringTimer = nil;

    if (localICECandidates.count)
    {
        NSLog(@"MXCall] onICECandidate: Send %tu candidates", localICECandidates.count);

        NSDictionary *content = @{
                                  @"version": @(0),
                                  @"call_id": _callId,
                                  @"candidates": localICECandidates
                                  };

        [_callSignalingRoom sendEventOfType:kMXEventTypeStringCallCandidates content:content success:nil failure:^(NSError *error) {
            NSLog(@"[MXCall] onICECandidate: Warning: Cannot send m.call.candidates event. Error: %@", error);
        }];

        [localICECandidates removeAllObjects];
    }
}

- (void)callStackCall:(id<MXCallStackCall>)callStackCall onError:(NSError *)error
{
    NSLog(@"[MXCall] callStackCall didEncounterError: %@", error);
    [self didEncounterError:error];
}


#pragma mark - Private methods
- (void)terminateWithReason:(MXEvent*)event
{
    if (inviteExpirationTimer)
    {
        [inviteExpirationTimer invalidate];
        inviteExpirationTimer = nil;
    }

    // Do not refresh TURN servers config anymore
    [localIceGatheringTimer invalidate];
    localIceGatheringTimer = nil;

    // Terminate the call at the stack level
    [callStackCall end];

    [self setState:MXCallStateEnded reason:event];
}

- (void)didEncounterError:(NSError*)error
{
    if ([_delegate respondsToSelector:@selector(call:didEncounterError:)])
    {
        [_delegate call:self didEncounterError:error];
    }
}

- (void)expireCallInvite
{
    if (inviteExpirationTimer)
    {
        inviteExpirationTimer = nil;

        if (!_isIncoming)
        {
            // Terminate the call at the stack level we initiated
            [callStackCall end];
        }

        // Send the notif that the call expired to the app
        [self setState:MXCallStateInviteExpired reason:nil];

        // And set the final state: MXCallStateEnded
        [self setState:MXCallStateEnded reason:nil];

        // The call manager can now ignore this call
        [callManager removeCall:self];
    }
}

- (void)onCallAnsweredElsewhere
{
    // Send the notif that the call has been answered from another device to the app
    [self setState:MXCallStateAnsweredElseWhere reason:nil];

    // And set the final state: MXCallStateEnded
    [self setState:MXCallStateEnded reason:nil];

    // The call manager can now ignore this call
    [callManager removeCall:self];
}

@end
