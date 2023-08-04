//
//  AppDelegate+notification.m
//  pushtest
//
//  Created by Robert Easterday on 10/26/12.
//
//

#import "AppDelegate+notification.h"
#import "PushPlugin.h"
#import <objc/runtime.h>
#import <UserNotifications/UserNotifications.h>

static char launchNotificationKey;
static char coldstartKey;
NSString *const pushPluginApplicationDidBecomeActiveNotification = @"pushPluginApplicationDidBecomeActiveNotification";
// Timer that will be used to check if this plugin has been registered and is available to be used and send data to the app.
NSTimer *checkPluginReadyTimer;

@implementation AppDelegate (notification)

- (id) getCommandInstance:(NSString*)className
{
    return [self.viewController getCommandInstance:className];
}

// its dangerous to override a method from within a category.
// Instead we will use method swizzling. we set this up in the load call.
+ (void)load
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class class = [self class];

        SEL originalSelector = @selector(init);
        SEL swizzledSelector = @selector(pushPluginSwizzledInit);

        Method original = class_getInstanceMethod(class, originalSelector);
        Method swizzled = class_getInstanceMethod(class, swizzledSelector);

        BOOL didAddMethod =
        class_addMethod(class,
                        originalSelector,
                        method_getImplementation(swizzled),
                        method_getTypeEncoding(swizzled));

        if (didAddMethod) {
            class_replaceMethod(class,
                                swizzledSelector,
                                method_getImplementation(original),
                                method_getTypeEncoding(original));
        } else {
            method_exchangeImplementations(original, swizzled);
        }
    });
}

- (AppDelegate *)pushPluginSwizzledInit
{
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    center.delegate = self;

    [[NSNotificationCenter defaultCenter]addObserver:self
                                            selector:@selector(pushPluginOnApplicationDidBecomeActive:)
                                                name:UIApplicationDidBecomeActiveNotification
                                              object:nil];

    // Cordova Plugin Push issues #1 and #5. Define a listener for the UIApplicationDidFinishLaunchingNotification event to get the data of the notification that opened the app from scratch.
    // Also, this method is called when app is finished launching and ready to present any windows to the user (according to the lifecycle of the iOS app).
    // https://github.com/TransformativeMed/cordova-plugin-push/issues/5
    // https://github.com/TransformativeMed/cordova-plugin-push/issues/1
    // Helpful documentation about lifecycle: https://medium.com/@theiOSzone/briefly-about-the-ios-application-lifecycle-92f0c830b754
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(getDataNotificationLaunchedApp:)
                                                 name:UIApplicationDidFinishLaunchingNotification
                                               object:nil];

    // This actually calls the original init method over in AppDelegate. Equivilent to calling super
    // on an overrided method, this is not recursive, although it appears that way. neat huh?
    return [self pushPluginSwizzledInit];
}

// Cordova Plugin Push issues #1 and #5. Initialize the listener for the UIApplicationDidFinishLaunchingNotification event that will help us to capture the data of the notification that started the app
// from scratch. Also, since this listener also runs when the app is opened by the user then it will be used to request permissions to the user about to receive normal and critical notifications
// at the start of the app.
// https://github.com/TransformativeMed/cordova-plugin-push/issues/1
// https://github.com/TransformativeMed/cordova-plugin-push/issues/5
// This code will be called immediately after application:didFinishLaunchingWithOptions event once the app is opened/loaded correctly.
- (void)getDataNotificationLaunchedApp:(NSNotification *)notification {
    
    // Cordova Plugin Push issue #1. Check if the app has the following option permissions to display Normal/Critical Push Notifications on screen (sent via APNS), even if the app is on foreground.
    [UNUserNotificationCenter currentNotificationCenter].delegate = self;
    // - UNAuthorizationOptionAlert: Show notifications on screen.
    // - UNAuthorizationOptionCriticalAlert: Show critical notifications on screen.
    // - UNAuthorizationOptionSound: Play a sound when the app receives a notification (no matter the type).
    // - UNAuthorizationOptionBadge: Update the badge number when a notifications arrives.
    UNAuthorizationOptions authOptions = UNAuthorizationOptionAlert | UNAuthorizationOptionCriticalAlert | UNAuthorizationOptionSound  | UNAuthorizationOptionBadge;
    [[UNUserNotificationCenter currentNotificationCenter] requestAuthorizationWithOptions:authOptions completionHandler:^(BOOL granted, NSError * _Nullable error) {
        if(!error){
            
            // The following line allows us to capture the push notification in the app.
            [[UIApplication sharedApplication] registerForRemoteNotifications];
        }
    }];
    
    // Cordova Plugin Push issue #5.
    // When the app is closed and is opened by a push notification (received in the phone and/or tapped by the user from the OS tray), the data of that notification must be captured to be sent
    // to the app once it has been started. This is important to prevent the data of the pressed notification from being lost when the app is opened.
    // Also, the coldstart flag will be updated to let us know if the app was opened from scratch.
    if (notification)
    {
        NSDictionary *launchOptions = [notification userInfo];
        if (launchOptions) {
            NSLog(@"coldstart");
            self.launchNotification = [launchOptions objectForKey: @"UIApplicationLaunchOptionsRemoteNotificationKey"];
            self.coldstart = [NSNumber numberWithBool:YES];
        } else {
            NSLog(@"not coldstart");
            self.coldstart = [NSNumber numberWithBool:NO];
        }
        
    }

}

- (void)application:(UIApplication *)application didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken {
    PushPlugin *pushHandler = [self getCommandInstance:@"PushNotification"];
    [pushHandler didRegisterForRemoteNotificationsWithDeviceToken:deviceToken];
}

- (void)application:(UIApplication *)application didFailToRegisterForRemoteNotificationsWithError:(NSError *)error {
    PushPlugin *pushHandler = [self getCommandInstance:@"PushNotification"];
    [pushHandler didFailToRegisterForRemoteNotificationsWithError:error];
}

// General listener invoked when a push notification is received on the phone, no matter the app status (foreground, background or stand by/closed),
// but the FOREGROUND case is ignored, since it will be handled by the "willPresentNotification" event.
- (void)application:(UIApplication *)application didReceiveRemoteNotification:(NSDictionary *)userInfo fetchCompletionHandler:(void (^)(UIBackgroundFetchResult))completionHandler {
    NSLog(@"didReceiveNotification with fetchCompletionHandler");
    
    // App is in background or in stand-by, send the data of the received push notification to the CORES Mobile app.
    if (application.applicationState != UIApplicationStateActive) {

        NSLog(@"app in background or stand-by");

        // do some convoluted logic to find out if this should be a silent push.
        long silent = 0;
        id aps = [userInfo objectForKey:@"aps"];
        id contentAvailable = [aps objectForKey:@"content-available"];
        if ([contentAvailable isKindOfClass:[NSString class]] && [contentAvailable isEqualToString:@"1"]) {
            silent = 1;
        } else if ([contentAvailable isKindOfClass:[NSNumber class]]) {
            silent = [contentAvailable integerValue];
        }

        if (silent == 1) {
            NSLog(@"this should be a silent push");
            void (^safeHandler)(UIBackgroundFetchResult) = ^(UIBackgroundFetchResult result){
                dispatch_async(dispatch_get_main_queue(), ^{
                    completionHandler(result);
                });
            };

            PushPlugin *pushHandler = [self getCommandInstance:@"PushNotification"];

            if (pushHandler.handlerObj == nil) {
                pushHandler.handlerObj = [NSMutableDictionary dictionaryWithCapacity:2];
            }

            id notId = [userInfo objectForKey:@"notId"];
            if (notId != nil) {
                NSLog(@"Push Plugin notId %@", notId);
                [pushHandler.handlerObj setObject:safeHandler forKey:notId];
            } else {
                NSLog(@"Push Plugin notId handler");
                [pushHandler.handlerObj setObject:safeHandler forKey:@"handler"];
            }

            pushHandler.notificationMessage = userInfo;
            pushHandler.isInline = NO;
            
            NSLog(@"didReceiveRemoteNotification in-background ");
            
            if([self.coldstart boolValue] == YES){
                
                // Cordova Push Plugin issues #5, #3 and #1.
                // https://github.com/TransformativeMed/cordova-plugin-push/issues/5
                // https://github.com/TransformativeMed/cordova-plugin-push/issues/3
                // https://github.com/TransformativeMed/cordova-plugin-push/issues/1
                // Wait a few seconds before to send the data of the received push notification to the CORES Mobile JS logic,
                // since the app was opened from scratch by the OS and and the Cordova plugin may not be available yet.
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [pushHandler notificationReceived];
                    completionHandler(UIBackgroundFetchResultNewData);
                });
                
            } else {
                
                [pushHandler notificationReceived];
                completionHandler(UIBackgroundFetchResultNewData);
                
            }
            
        } else {
            NSLog(@"just put it in the shade");
            //save it for later
            completionHandler(UIBackgroundFetchResultNewData);
        }

    } else {
        completionHandler(UIBackgroundFetchResultNoData);
    }
    
    // Cordova Plugin Push issue #3.
    // https://github.com/TransformativeMed/cordova-plugin-push/issues/3
    // Since iOS will automatically group the notifications, we need to display a local push notification that will help us to open all notification
    // at the same time in the "Notification Viewer" of the CORES Mobile app.
    // But only if there are 1+ notifications in the Notification Center of the phone.
    [self displayOpenAllLocalNotification];
    
}

- (void)checkUserHasRemoteNotificationsEnabledWithCompletionHandler:(nonnull void (^)(BOOL))completionHandler
{
    [[UNUserNotificationCenter currentNotificationCenter] getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings * _Nonnull settings) {

        switch (settings.authorizationStatus)
        {
            case UNAuthorizationStatusDenied:
            case UNAuthorizationStatusNotDetermined:
                completionHandler(NO);
                break;
            case UNAuthorizationStatusAuthorized:
                completionHandler(YES);
                break;
        }
    }];
}

- (void)pushPluginOnApplicationDidBecomeActive:(NSNotification *)notification {

    NSLog(@"active");
        
    NSString *firstLaunchKey = @"firstLaunchKey";
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:@"phonegap-plugin-push"];
    if (![defaults boolForKey:firstLaunchKey]) {
        NSLog(@"application first launch: remove badge icon number");
        [defaults setBool:YES forKey:firstLaunchKey];
        
        // Cordova Plugin Push issues #3 and #5. DON'T remove the notifications from the OS tray until they are discarded or opened by the user.
        // Also, when the user does a down swipe to open the Notification Center this event is triggered, that is why removing the notifications from the tray should be avoided.
        // https://github.com/TransformativeMed/cordova-plugin-push/issues/3
        // https://github.com/TransformativeMed/cordova-plugin-push/issues/5
        // To clear the badge number without remove the notifications from the tray we need to set -1 instead of 0.
        // https://developer.apple.com/forums/thread/7598
        [[UIApplication sharedApplication] setApplicationIconBadgeNumber:-1];
    }

    UIApplication *application = notification.object;

    PushPlugin *pushHandler = [self getCommandInstance:@"PushNotification"];
    if (pushHandler.clearBadge) {
        NSLog(@"PushPlugin clearing badge");
        //zero badge
        // Cordova Plugin Push issues #3 and #5. DON'T remove the notifications from the OS tray until they are discarded or opened by the user. Only clean the badge number of the app.
        // Also, when the user does a down swipe to open the Notification Center this event is triggered, that is why removing the notifications from the tray should be avoided.
        // https://github.com/TransformativeMed/cordova-plugin-push/issues/3
        // https://github.com/TransformativeMed/cordova-plugin-push/issues/5
        // To clear the badge number without remove the notifications from the tray we need to set -1 instead of 0.
        // https://developer.apple.com/forums/thread/7598
        application.applicationIconBadgeNumber = -1;
    } else {
        NSLog(@"PushPlugin skip clear badge");
    }

    if (self.launchNotification) {
        pushHandler.isInline = NO;
        pushHandler.coldstart = [self.coldstart boolValue];
        pushHandler.notificationMessage = self.launchNotification;
        self.launchNotification = nil;
        self.coldstart = [NSNumber numberWithBool:NO];
        [pushHandler performSelectorOnMainThread:@selector(notificationReceived) withObject:pushHandler waitUntilDone:NO];
    }
        
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions options))completionHandler
{
    NSLog( @"NotificationCenter Handle push from foreground" );
    NSLog(@"Push Plugin willPresentNotification ---------------> %@", notification.request.content.userInfo);
    
    PushPlugin *pushHandler = [self getCommandInstance:@"PushNotification"];
    pushHandler.notificationMessage = notification.request.content.userInfo;
    pushHandler.isInline = YES;
    pushHandler.isTapped = NO;
    [pushHandler notificationReceived];

    // Cordova Plugin Push issue #3: Always displays the notification in the Notification Center of the phone even if the app is in foreground.
    // https://github.com/TransformativeMed/cordova-plugin-push/issues/3
    // Display the notification on the OS tray including the sound and badge number contained in the push notification.
    completionHandler(UNNotificationPresentationOptionAlert | UNNotificationPresentationOptionSound | UNNotificationPresentationOptionBadge);
}

// Cordova Push Plugin issues #3 and #5. Get the data of the pressed notification (single or grouped notifications) to send it to the CORES Mobile app.
// https://github.com/TransformativeMed/cordova-plugin-push/issues/5
// https://github.com/TransformativeMed/cordova-plugin-push/issues/3
- (void) sendResponseDataOfPressedNotification: (NSDictionary *)userInfo : (PushPlugin *) pushHandler {
    
    // Check if the notification was sent by the APNS (triggered by the CORES API) or it is a local push notification created by us to let the user open all notifications ("open all" notification).
    if ( [userInfo objectForKey:@"coresPayload"] ) {
        
        // A single notification was pressed. Send its data to the CORES Mobile app, initializing some values as empty and indicating it was tapped.
        pushHandler.notificationMessage = userInfo;
        pushHandler.isTapped = YES;
        pushHandler.notificationIDsToOpen = @"";
        pushHandler.notificationsGroupedContentList = @"";
        pushHandler.coldstart = [self.coldstart boolValue];
        [pushHandler notificationReceived];
        
    } else {
    
        // This is a local push notification (grouped notifications).
        // Initialize the data that will be sent to the CORES Mobile app to show all notifications in the Inbox page (the Notification Viewer mode of that component).
        NSMutableArray *notificationIDlistToOpen = [[NSMutableArray alloc] init];
        
        // Iterate the notifications that are currently displayed in the notification center of the phone.
        [[UNUserNotificationCenter currentNotificationCenter] getDeliveredNotificationsWithCompletionHandler:^(NSArray<UNNotification *> * _Nonnull notifications) {
            
            int notificationsCount = notifications.count;
            for (int i=0; i<notificationsCount; i++){
                
                // Get data of the existing notification that is displayed in the Notification center.
                UNNotification *existingNotification = [notifications objectAtIndex:i];//notification.request.content.userInfo;
                
                NSDictionary *userInfo = existingNotification.request.content.userInfo;
                
                for(id key in userInfo) {
                    
                    if([key isEqualToString:@"coresPayload"]){
                        
                        NSDictionary *coresPayloadObject = [userInfo objectForKey:key];
                        
                        for(id coresPayloadKey in coresPayloadObject) {
                            
                            if([coresPayloadKey isEqualToString:@"notification_id"]){
                               
                                [notificationIDlistToOpen addObject: [coresPayloadObject objectForKey: coresPayloadKey]];
                                
                            }
                            
                        }
                        
                    }

                }
                    
            }
            
            // Remove all notifications that are waiting in the notification center:
            // - setting a 0 value to remove the badge number of the app.
            [[UIApplication sharedApplication] setApplicationIconBadgeNumber:0];
            // - Remove all delivered notifications (items displayed in the notification center of the phone).
            [[UNUserNotificationCenter currentNotificationCenter] removeAllDeliveredNotifications];
            // - Remove all pending notifications which are not delivered yet but scheduled (like the local notification created by us to open all notifications at the same time).
            [[UNUserNotificationCenter currentNotificationCenter] removeAllPendingNotificationRequests];
            
            // Create a single string with all notification IDs, concatenating them with a comma.
            NSString *notificationsToOpen = [notificationIDlistToOpen componentsJoinedByString:@","];
            
            // Prepare the data to send the notification data to the CORES Mobie app.
            pushHandler.isTapped = YES;
            pushHandler.coldstart = [self.coldstart boolValue];
            pushHandler.notificationIDsToOpen = notificationsToOpen;
            pushHandler.notificationsGroupedContentList = @"YES";
            [pushHandler notificationReceived];

        }];
        
    }

}

// Cordova Plugin Push issue #5.
// https://github.com/TransformativeMed/cordova-plugin-push/issues/5
// Method invoked to verify if the Cordova Plugin Push is ready to invoke the method used to send data to the CORES Mobile app.
- (void) onPluginReady:(NSTimer *)timer {
    
    // Get from the timer the response data of the pressed notification (the method who invoked this function, check the "didReceiveNotificationResponse" method ).
    NSDictionary *userInfo = [timer userInfo];
    
    // Initialize the PushPlugin class of the Cordova Push plugin and check if it was initialized correctly (checking its ID auto assigned by
    // Cordova). If it is nil that means the Cordova plugins are not ready to be invoked (like for example: when the app was opened from scratch and the plugins are being initialized).
    PushPlugin *pushHandler = [self getCommandInstance:@"PushNotification"];
    if(pushHandler.callbackId != nil){
        
        // If the Cordova Push plugin is ready then we can finish the timer and proceed to send the data of the pressed notification to CORES Mobile JS logic.
        if(checkPluginReadyTimer != nil){
            [checkPluginReadyTimer invalidate];
            checkPluginReadyTimer = nil;
        }
        
        [self sendResponseDataOfPressedNotification : userInfo : pushHandler];
        
    }
}

// Cordova Plugin Push #3.
// https://github.com/TransformativeMed/cordova-plugin-push/issues/3
// Method used to create a local/scheduled notification that will be displayed at the top of all app notifications to let the user open all of them in the Inbox page.
- (void) displayOpenAllLocalNotification {
    
    // Get data from existing notifications in the notification center
    [[UNUserNotificationCenter currentNotificationCenter] getDeliveredNotificationsWithCompletionHandler:^(NSArray<UNNotification *> * _Nonnull notifications) {
        
        NSLog(@"Unopened notifications inside the Notification Center: %lu", [notifications count]);

        if([notifications count] > 1){
            
            // Prepare the object that will store the content of each notification received to create the grouped notification.
            NSString *newOpenAllBodyContent = [[NSString alloc] initWithString:@""];
            
            // Remove all notifications that are waiting in the notification center:
            // - setting a 0 value to remove the badge number of the app.
            [[UIApplication sharedApplication] setApplicationIconBadgeNumber:0];
            // - Remove all delivered notifications (items displayed in the notification center of the phone).
            [[UNUserNotificationCenter currentNotificationCenter] removeAllDeliveredNotifications];
            // - Remove all pending notifications which are not delivered yet but scheduled (like the local notification created by us to open all notifications at the same time).
            [[UNUserNotificationCenter currentNotificationCenter] removeAllPendingNotificationRequests];
           
            // Trigger a new local push notification that will be displayed at the top of the list to let the user open all push notifications
            // in the "Notification Viewer" mode of the Inbox page of the CORES Mobile app.
            UNMutableNotificationContent* content = [[UNMutableNotificationContent alloc] init];
            
            int notificationsCount = notifications.count;
            
            
            // Iterate the notifications that were displayed in the OS tray. Usually, the first notification is the single one sent by the APNS and the other is the
            // local notification created by us (the "open all" notification) to group these notifications when there are more than 1 in the tray.
            for (int i=0; i<notificationsCount; i++){
                
                // Get data of the existing notification that is displayed in the Notification center.
                UNNotification *existingNotification = [notifications objectAtIndex:i];
                
                NSDictionary *userInfo = existingNotification.request.content.userInfo;
                
                // Check if the current notification is the one received by the APNS or the "open all" local notification.
                if ([userInfo objectForKey:@"coresPayload"]) {
                    
                    // This is a notification sent by APNS. This notification ALWAYS contains the "coresPayload" object that was included by CORES API (backend) to send
                    // values used in the CORES Mobile app.
                    
                    // Get the content of this notification to include it in the body of the "open all" notification.
                    for(id key in userInfo) {
                        
                        if([key isEqualToString:@"aps"]){
                            
                            NSDictionary *apsObject = [userInfo objectForKey:key];
                            
                            for(id apsKey in apsObject) {
                                
                                if([apsKey isEqualToString:@"alert"]){
                                    
                                    NSDictionary *alertObject = [apsObject objectForKey:apsKey];
                                    
                                    for(id alertKey in alertObject) {
                                        
                                        if([alertKey isEqualToString:@"body"]){
                                            
                                            // Grab the body of this notification. It will be included in the body of the "open all" notification.
                                            newOpenAllBodyContent = [newOpenAllBodyContent stringByAppendingString: alertObject[alertKey] ];
                                            
                                            // Add a new line at the end of this string to be able to concatenate values in the body of the "open all" notification
                                            // and display the body correctly.
                                            if(i == 0){
                                                newOpenAllBodyContent = [newOpenAllBodyContent stringByAppendingString: @"\n"];
                                            }
                                            
                                        }
                                        
                                    }
                                    
                                }
                                
                            }
                            
                        }

                    }
                    
                    // Set the title that will be used in the "open all" notification.
                    content.title = [NSString localizedUserNotificationStringForKey:@"CORES Mobile \n There are pending notifications" arguments:nil];
                    
                } else {
                    
                    // "Open all" notification (local notification created to replace the existing notifications of the tray and simulate have a grouper with the
                    // content of all of them).
                    
                    // Get the content of the existing "open all" notification since we need to update its body to include the new single notification that was received.
                    UNNotificationContent *existingOpenAllObject = existingNotification.request.content;
                    NSString *existingOpenAllBody = existingOpenAllObject.body;
                    
                    // Get the number of notifications that were grouped by the existing "open all" notification (its body has the content of each received notification
                    // concatenated by "\n" char.
                    NSArray *groupedNotificationInOpenAllBody = [existingOpenAllBody componentsSeparatedByString:@"\n"];
                    
                    // Build the body of the new "open all" notification that will replace the existing one. It will include the last notification received at the top. We need to set a limit in the number of lines that will be displayed in the body of this new "open all" notification to prevent errors in iOS.
                    if(groupedNotificationInOpenAllBody.count > 3){
                        
                        for (int pos=0; pos < 3; pos++){
                            
                            newOpenAllBodyContent = [newOpenAllBodyContent stringByAppendingString: groupedNotificationInOpenAllBody[pos] ];
                            
                            if(pos+1 < groupedNotificationInOpenAllBody.count){
                                newOpenAllBodyContent = [newOpenAllBodyContent stringByAppendingString: @"\n"];
                            }
                        }
                        
                        newOpenAllBodyContent = [newOpenAllBodyContent stringByAppendingString: @"\n..."];
                        
                    } else {
                        newOpenAllBodyContent = [newOpenAllBodyContent stringByAppendingString: existingOpenAllBody];
                    }
                    
                    // Create the title that will be displayed in this "open all" notification.
                    content.title = [NSString localizedUserNotificationStringForKey: @"CORES Mobile\nThere are pending notifications" arguments:nil];
                    
                }
                    
            }
            
            // Set the string body of the new "open all" notification.
            content.body = [NSString localizedUserNotificationStringForKey:newOpenAllBodyContent arguments:nil];

            // Specify a grouping name for this local notification so that the OS understands that this local notification is part of the app and should not replace the existing
            // that are displayed in the Notification Center.
            content.threadIdentifier = @"cores-mobile-grouper";
            
            // Set an optional text that will be displayed in case there are a lot of notifications.
            if (@available(iOS 12.0, *)) {
                content.summaryArgument = @"There are pending notifications";
            }

            // Deliver the "open all" local notification inmediately.
            UNTimeIntervalNotificationTrigger* trigger = [UNTimeIntervalNotificationTrigger triggerWithTimeInterval:0.1 repeats:NO];
            UNNotificationRequest* request = [UNNotificationRequest requestWithIdentifier:@"FiveSecond" content:content trigger:trigger];

            // Schedule the notification to display it on screen.
            UNUserNotificationCenter* center = [UNUserNotificationCenter currentNotificationCenter];
            [center addNotificationRequest:request withCompletionHandler:nil];
           
        }
       
    }];
    
}

// Cordova Plugin Push #5. Method called when a push notification is pressed to let the CORES Mobile app know which action was selected by the user for a given notification (single or grouped notifications).
// According to the app status (foreground, background or closed) the app will flex its content.
// https://github.com/TransformativeMed/cordova-plugin-push/issues/5
- (void)userNotificationCenter:(UNUserNotificationCenter *)center didReceiveNotificationResponse:(UNNotificationResponse *)response
         withCompletionHandler:(void(^)())completionHandler
{
    NSLog(@"Push Plugin didReceiveNotificationResponse: actionIdentifier %@, notification: %@", response.actionIdentifier,
          response.notification.request.content.userInfo);
    
    NSMutableDictionary *userInfo = [response.notification.request.content.userInfo mutableCopy];
    
    // If the notification has no actions, then we can assume this event was triggered by a tapped notification.
    if([response.actionIdentifier rangeOfString:@"UNNotificationDefaultActionIdentifier"].location == NSNotFound) {
        [userInfo setObject:response.actionIdentifier forKey:@"actionCallback"];
    }
    
    NSLog(@"Push Plugin userInfo %@", userInfo);
    
    switch ([UIApplication sharedApplication].applicationState) {
        case UIApplicationStateActive:
        {
            // The app is in foreground or background, so we can immediately send the data of the pressed notification to the CORES Mobile JS logic.
            PushPlugin *pushHandler = [self getCommandInstance:@"PushNotification"];
            [self sendResponseDataOfPressedNotification : userInfo : pushHandler];
            completionHandler();
            
            break;
        }
        case UIApplicationStateInactive:
        {
            NSLog(@"coldstart");
            
            if([response.actionIdentifier rangeOfString:@"UNNotificationDefaultActionIdentifier"].location == NSNotFound) {
                self.launchNotification = userInfo;
            }
            else {
                self.launchNotification = response.notification.request.content.userInfo;
            }
            
            self.coldstart = [NSNumber numberWithBool:YES];

            // Since this logic can run in a coldstart situation (when the app is closed and the OS opens it because a notification was pressed),
            // we need to check if the Cordova plugin is ready to be invoked to send the data to the CORES Mobile JS logic.

            // Create a timer object to check if the plugin is ready to be invoked, checking every second if that is ready.
            checkPluginReadyTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                                    target:self
                                                                    selector:@selector(onPluginReady:)
                                                                    userInfo:userInfo
                                                                    repeats:YES];
            break;
        }
        case UIApplicationStateBackground:
        {
            void (^safeHandler)(void) = ^(void){
                dispatch_async(dispatch_get_main_queue(), ^{
                    completionHandler();
                });
            };

            PushPlugin *pushHandler = [self getCommandInstance:@"PushNotification"];

            if (pushHandler.handlerObj == nil) {
                pushHandler.handlerObj = [NSMutableDictionary dictionaryWithCapacity:2];
            }

            id notId = [userInfo objectForKey:@"notId"];
            if (notId != nil) {
                NSLog(@"Push Plugin notId %@", notId);
                [pushHandler.handlerObj setObject:safeHandler forKey:notId];
            } else {
                NSLog(@"Push Plugin notId handler");
                [pushHandler.handlerObj setObject:safeHandler forKey:@"handler"];
            }

            pushHandler.notificationMessage = userInfo;
            pushHandler.isInline = NO;

            [pushHandler performSelectorOnMainThread:@selector(notificationReceived) withObject:pushHandler waitUntilDone:NO];
        }
        
    }
    
}


// The accessors use an Associative Reference since you can't define a iVar in a category
// http://developer.apple.com/library/ios/#documentation/cocoa/conceptual/objectivec/Chapters/ocAssociativeReferences.html
- (NSMutableArray *)launchNotification
{
    return objc_getAssociatedObject(self, &launchNotificationKey);
}

- (void)setLaunchNotification:(NSDictionary *)aDictionary
{
    objc_setAssociatedObject(self, &launchNotificationKey, aDictionary, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (NSNumber *)coldstart
{
    return objc_getAssociatedObject(self, &coldstartKey);
}

- (void)setColdstart:(NSNumber *)aNumber
{
    objc_setAssociatedObject(self, &coldstartKey, aNumber, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)dealloc
{
    self.launchNotification = nil; // clear the association and release the object
    self.coldstart = nil;
}

@end
