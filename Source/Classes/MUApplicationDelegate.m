/* Copyright (C) 2009-2010 Mikkel Krautz <mikkel@krautz.dk>

   All rights reserved.

   Redistribution and use in source and binary forms, with or without
   modification, are permitted provided that the following conditions
   are met:

   - Redistributions of source code must retain the above copyright notice,
     this list of conditions and the following disclaimer.
   - Redistributions in binary form must reproduce the above copyright notice,
     this list of conditions and the following disclaimer in the documentation
     and/or other materials provided with the distribution.
   - Neither the name of the Mumble Developers nor the names of its
     contributors may be used to endorse or promote products derived from this
     software without specific prior written permission.

   THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
   ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
   LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
   A PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE FOUNDATION OR
   CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
   EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
   PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
   PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
   LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
   NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
   SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/

#import "MUApplicationDelegate.h"

#import "MUWelcomeScreenPhone.h"
#import "MUWelcomeScreenPad.h"
#import "MUDatabase.h"
#import "MUPublicServerList.h"
#import "MUConnectionController.h"
#import "MUNotificationController.h"
#import "MURemoteControlServer.h"

#import <MumbleKit/MKAudio.h>
#import <MumbleKit/MKConnectionController.h>
#import <MumbleKit/MKVersion.h>

#import "PLCrashReporter.h"

@interface MUApplicationDelegate () <UIApplicationDelegate, UIAlertViewDelegate> {
    UIWindow                  *window;
    UINavigationController    *navigationController;
    MUPublicServerListFetcher *_publistFetcher;
#ifdef MUMBLE_BETA_DIST
    MUVersionChecker          *_verCheck;
#endif
}
- (void) setupAudio;
- (void) forceKeyboardLoad;
- (void) notifyCrash;
@end

@implementation MUApplicationDelegate

@synthesize window;
@synthesize navigationController;

- (void) notifyCrash {
    PLCrashReporter *crashReporter = [PLCrashReporter sharedReporter];
    if ([crashReporter hasPendingCrashReport]) {
        BOOL autoReport = [[NSUserDefaults standardUserDefaults] boolForKey:@"AutoCrashReport"];
        if (autoReport) {
            [self sendPendingCrashReport];
        } else {
            NSString *title = NSLocalizedString(@"Crash Reporting", nil);
            NSString *msg = NSLocalizedString(@"We're terribly sorry. It looks like Mumble has recently crashed. "
                                              @"Do you want to send a crash report to the Mumble developers?", nil);
            UIAlertView *alertView = [[UIAlertView alloc] initWithTitle:title
                                                                message:msg
                                                               delegate:self
                                                      cancelButtonTitle:NSLocalizedString(@"No", nil)
                                                      otherButtonTitles:NSLocalizedString(@"Yes", nil),
                                                                        NSLocalizedString(@"Always", nil), nil];
            [alertView show];
            [alertView release];
        }
    }
}

- (void) sendPendingCrashReport {
    NSError *err = nil;
    PLCrashReporter *crashReporter = [PLCrashReporter sharedReporter];

    NSData *crashData = [crashReporter loadPendingCrashReportDataAndReturnError:&err];
    if (crashData == nil) {
        NSLog(@"MUApplicationDelegate: unable to load pending crash report: %@", err);
        return;
    }
    if (![crashReporter purgePendingCrashReportAndReturnError:&err]) {
        NSLog(@"MUApplicationDelegate: unable to purge pending crash report: %@", err);
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:
                                 [NSString stringWithFormat:@"https://mumblecrash.appspot.com/report?ver=%@&gitrev=%@",
                                  [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"],
                                  [[NSBundle mainBundle] objectForInfoDictionaryKey:@"MumbleGitRevision"], nil]]];
    [req setHTTPMethod:@"POST"];
    [req setHTTPBody:crashData];
    
    [NSURLConnection sendAsynchronousRequest:req queue:[NSOperationQueue mainQueue] completionHandler:^(NSURLResponse *resp, NSData *data, NSError *err) {
        if (err != nil) {
            NSLog(@"MUApplicationDelegate: unable to submit crash report: %@", err);
        }
    }];
}

- (void) alertView:(UIAlertView *)alertView didDismissWithButtonIndex:(NSInteger)buttonIndex {
    if (buttonIndex == 0) {
        NSError *err = nil;
        PLCrashReporter *crashReporter = [PLCrashReporter sharedReporter];
        if (![crashReporter purgePendingCrashReportAndReturnError:&err]) {
            NSLog(@"MUApplicationDelegate: unable to purge pending crash report: %@", err);
        }
        return;
    }
    if (buttonIndex == 2)
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"AutoCrashReport"];
    [self sendPendingCrashReport];
}

- (BOOL) application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    NSError *err = nil;
    [[PLCrashReporter sharedReporter] enableCrashReporterAndReturnError:&err];
    if (err != nil) {
        NSLog(@"MUApplicationDelegate: Unable to enable PLCrashReporter: %@", err);
    }

#ifdef MUMBLE_BETA_DIST
    _verCheck = [[MUVersionChecker alloc] init];
#endif
    
    // Reset application badge, in case something brought it into an inconsistent state.
    [[UIApplication sharedApplication] setApplicationIconBadgeNumber:0];
    
    // Initialize the notification controller
    [MUNotificationController sharedController];
    
    // Try to fetch an updated public server list
    _publistFetcher = [[MUPublicServerListFetcher alloc] init];
    [_publistFetcher attemptUpdate];
    
    // Set MumbleKit release string
    [[MKVersion sharedVersion] setOverrideReleaseString:
        [NSString stringWithFormat:@"Mumble for iOS %@", [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"]]];
    
    // Enable Opus unconditionally
    [[MKVersion sharedVersion] setOpusEnabled:YES];

    // Register default settings
    [[NSUserDefaults standardUserDefaults] registerDefaults:[NSDictionary dictionaryWithObjectsAndKeys:
                                                                // Audio
                                                                [NSNumber numberWithFloat:1.0f],   @"AudioOutputVolume",
                                                                [NSNumber numberWithFloat:0.6f],   @"AudioVADAbove",
                                                                [NSNumber numberWithFloat:0.3f],   @"AudioVADBelow",
                                                                @"amplitude",                      @"AudioVADKind",
                                                                @"ptt",                            @"AudioTransmitMethod",
                                                                [NSNumber numberWithBool:YES],     @"AudioPreprocessor",
                                                                [NSNumber numberWithBool:YES],     @"AudioEchoCancel",
                                                                [NSNumber numberWithFloat:1.0f],   @"AudioMicBoost",
                                                                @"balanced",                       @"AudioQualityKind",
                                                                [NSNumber numberWithBool:NO],      @"AudioSidetone",
                                                                [NSNumber numberWithFloat:0.2f],   @"AudioSidetoneVolume",
                                                                // Network
                                                                [NSNumber numberWithBool:NO],      @"NetworkForceTCP",
                                                                @"MumbleUser",                     @"DefaultUserName",
                                                             nil]];
    
    [self reloadPreferences];
    [MUDatabase initializeDatabase];
    
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"RemoteControlServerEnabled"]) {
        [[MURemoteControlServer sharedRemoteControlServer] start];
    }
    
    // Put a background view in here, to have prettier transitions.
    UIImageView *bgView = [[[UIImageView alloc] initWithImage:[UIImage imageNamed:@"BackgroundTextureBlackGradient"]] autorelease];
    [bgView setFrame:[[UIScreen mainScreen] bounds]];
    [window addSubview:bgView];

    // Add our default navigation controller
    self.navigationController.toolbarHidden = YES;

    UIUserInterfaceIdiom idiom = [[UIDevice currentDevice] userInterfaceIdiom];
    UIViewController *welcomeScreen = nil;
    if (idiom == UIUserInterfaceIdiomPad) {
        welcomeScreen = [[MUWelcomeScreenPad alloc] init];
        [navigationController pushViewController:welcomeScreen animated:YES];
        [welcomeScreen release];
    } else {
        welcomeScreen = [[MUWelcomeScreenPhone alloc] init];
        [navigationController pushViewController:welcomeScreen animated:YES];
        [welcomeScreen release];
    }
    
    [window setRootViewController:navigationController];
    [window makeKeyAndVisible];
    
    [self notifyCrash];

    NSURL *url = [launchOptions objectForKey:UIApplicationLaunchOptionsURLKey];
    if ([[url scheme] isEqualToString:@"mumble"]) {
        MUConnectionController *connController = [MUConnectionController sharedController];
        NSString *hostname = [url host];
        NSNumber *port = [url port];
        NSString *username = [url user];
        NSString *password = [url password];
        [connController connetToHostname:hostname port:port ? [port integerValue] : 64738 withUsername:username andPassword:password withParentViewController:welcomeScreen];
        return YES;
    }
    return NO;
}

- (BOOL) application:(UIApplication *)application openURL:(NSURL *)url sourceApplication:(NSString *)sourceApplication annotation:(id)annotation {
    if ([[url scheme] isEqualToString:@"mumble"]) {
        MUConnectionController *connController = [MUConnectionController sharedController];
        if ([connController isConnected]) {
            return NO;
        }
        NSString *hostname = [url host];
        NSNumber *port = [url port];
        NSString *username = [url user];
        NSString *password = [url password];
        [connController connetToHostname:hostname port:port ? [port integerValue] : 64738 withUsername:username andPassword:password withParentViewController:self.navigationController.visibleViewController];
        return YES;
    }
    return NO;
}

- (void) applicationWillTerminate:(UIApplication *)application {
    [MUDatabase teardown];
}

- (void) dealloc {
#ifdef MUMBLE_BETA_DIST
    [_verCheck release];
#endif
    [navigationController release];
    [window release];
    [super dealloc];
}

- (void) setupAudio {
    // Set up a good set of default audio settings.
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    MKAudioSettings settings;

    if ([[defaults stringForKey:@"AudioTransmitMethod"] isEqualToString:@"vad"])
        settings.transmitType = MKTransmitTypeVAD;
    else if ([[defaults stringForKey:@"AudioTransmitMethod"] isEqualToString:@"continuous"])
        settings.transmitType = MKTransmitTypeContinuous;
    else if ([[defaults stringForKey:@"AudioTransmitMethod"] isEqualToString:@"ptt"])
        settings.transmitType = MKTransmitTypeToggle;
    else
        settings.transmitType = MKTransmitTypeVAD;
    
    settings.vadKind = MKVADKindAmplitude;
    if ([[defaults stringForKey:@"AudioVADKind"] isEqualToString:@"snr"]) {
        settings.vadKind = MKVADKindSignalToNoise;
    } else if ([[defaults stringForKey:@"AudioVADKind"] isEqualToString:@"amplitude"]) {
        settings.vadKind = MKVADKindAmplitude;
    }
    
    settings.vadMin = [defaults floatForKey:@"AudioVADBelow"];
    settings.vadMax = [defaults floatForKey:@"AudioVADAbove"];
    
    NSString *quality = [defaults stringForKey:@"AudioQualityKind"];
    if ([quality isEqualToString:@"low"]) {
        settings.codec = MKCodecFormatSpeex;
        settings.quality = 16000;
        settings.audioPerPacket = 6;
    } else if ([quality isEqualToString:@"balanced"]) {
        // Will fall back to CELT if the 
        // server requires it for inter-op.
        settings.codec = MKCodecFormatOpus;
        settings.quality = 40000;
        settings.audioPerPacket = 2;
    } else if ([quality isEqualToString:@"high"] || [quality isEqualToString:@"opus"]) {
        // Will fall back to CELT if the 
        // server requires it for inter-op.
        settings.codec = MKCodecFormatOpus;
        settings.quality = 72000;
        settings.audioPerPacket = 1;
    } else {
        settings.codec = MKCodecFormatCELT;
        if ([[defaults stringForKey:@"AudioCodec"] isEqualToString:@"opus"])
            settings.codec = MKCodecFormatOpus;
        if ([[defaults stringForKey:@"AudioCodec"] isEqualToString:@"celt"])
            settings.codec = MKCodecFormatCELT;
        if ([[defaults stringForKey:@"AudioCodec"] isEqualToString:@"speex"])
            settings.codec = MKCodecFormatSpeex;
        settings.quality = [defaults integerForKey:@"AudioQualityBitrate"];
        settings.audioPerPacket = [defaults integerForKey:@"AudioQualityFrames"];
    }
    
    settings.noiseSuppression = -42; /* -42 dB */
    settings.amplification = 20.0f;
    settings.jitterBufferSize = 0; /* 10 ms */
    settings.volume = [defaults floatForKey:@"AudioOutputVolume"];
    settings.outputDelay = 0; /* 10 ms */
    settings.micBoost = [defaults floatForKey:@"AudioMicBoost"];
    settings.enablePreprocessor = [defaults boolForKey:@"AudioPreprocessor"];
    if (settings.enablePreprocessor) {
        settings.enableEchoCancellation = [defaults boolForKey:@"AudioEchoCancel"];
    } else {
        settings.enableEchoCancellation = NO;
    }

    settings.enableSideTone = [defaults boolForKey:@"AudioSidetone"];
    settings.sidetoneVolume = [defaults floatForKey:@"AudioSidetoneVolume"];
    
    MKAudio *audio = [MKAudio sharedAudio];
    [audio updateAudioSettings:&settings];
    [audio restart];
}

// Reload application preferences...
- (void) reloadPreferences {
    [self setupAudio];
}

- (void) forceKeyboardLoad {
    UITextField *textField = [[UITextField alloc] initWithFrame:CGRectZero];
    [window addSubview:textField];
    [textField release];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillShow:) name:UIKeyboardWillShowNotification object:nil];
    [textField becomeFirstResponder];
}

- (void) keyboardWillShow:(NSNotification *)notification {
    for (UIView *view in [window subviews]) {
        if ([view isFirstResponder]) {
            [view resignFirstResponder];
            [view removeFromSuperview];
            
            [[NSNotificationCenter defaultCenter] removeObserver:self name:UIKeyboardWillShowNotification object:nil];
        }
    }
}

- (void) applicationWillResignActive:(UIApplication *)application {
    // If we have any active connections, don't stop MKAudio. This is
    // for 'clicking-the-home-button' invocations of this method.
    //
    // In case we've been backgrounded by a phone call, MKAudio will
    // already have shut itself down.
    NSArray *connections = [[MKConnectionController sharedController] allConnections];
    if ([connections count] == 0) {
        NSLog(@"MumbleApplicationDelegate: Not connected to a server. Stopping MKAudio.");
        [[MKAudio sharedAudio] stop];
        
        // Also terminate the remote control server.
        [[MURemoteControlServer sharedRemoteControlServer] stop];
    }
}

- (void) applicationDidBecomeActive:(UIApplication *)application {
    // It is possible that we will become active after a phone call has ended.
    // In the case of phone calls, MKAudio will automatically stop itself, to
    // allow the phone call to go through. However, once we're back inside the
    // application, we have to start ourselves again.
    //
    // For regular backgrounding, we usually don't turn off the audio system, and
    // we won't have to start it again.
    if (![[MKAudio sharedAudio] isRunning]) {
        NSLog(@"MumbleApplicationDelegate: MKAudio not running. Starting it.");
        [[MKAudio sharedAudio] start];
        
        // Re-start the remote control server.
        [[MURemoteControlServer sharedRemoteControlServer] stop];
        [[MURemoteControlServer sharedRemoteControlServer] start];
    }
}

@end
