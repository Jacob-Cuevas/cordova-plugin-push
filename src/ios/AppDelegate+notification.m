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

static char launchNotificationKey;
static char coldstartKey;
NSString *const pushPluginApplicationDidBecomeActiveNotification = @"pushPluginApplicationDidBecomeActiveNotification";
// Timer that will be used to check if this plugin has been registered by the JS app (running the register method).
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

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(checkNotificationPermissions:)
                                                 name:UIApplicationDidFinishLaunchingNotification
                                               object:nil];

    // This actually calls the original init method over in AppDelegate. Equivilent to calling super
    // on an overrided method, this is not recursive, although it appears that way. neat huh?
    return [self pushPluginSwizzledInit];
}

// This code will be called immediately after application:didFinishLaunchingWithOptions:. We need
// to process notifications in cold-start situations
- (void)checkNotificationPermissions:(NSNotification *)notification
{

    // Check if the app has the following option permissions to display Normal/Critical Push Notifications on screen (sent via APNS), even if the app is on foreground:
    [UNUserNotificationCenter currentNotificationCenter].delegate = self;
    // - UNAuthorizationOptionAlert: Show notifications on screen.
    // - UNAuthorizationOptionCriticalAlert: Show critical notifications on screen.
    // - UNAuthorizationOptionSound: Play a sound when the app receives a notification (no matter the type).
    // - UNAuthorizationOptionBadge: Update the badge number when a notifications arrives.
    UNAuthorizationOptions authOptions = UNAuthorizationOptionAlert | UNAuthorizationOptionCriticalAlert | UNAuthorizationOptionSound  | UNAuthorizationOptionBadge;
    [[UNUserNotificationCenter currentNotificationCenter] requestAuthorizationWithOptions:authOptions completionHandler:^(BOOL granted, NSError * _Nullable error) {
        if(!error){
            NSLog(@"Native Push Notification Success");
            
            // The following line allows us to capture the push notification when the app is in foreground and display it on the screen.
            [[UIApplication sharedApplication] registerForRemoteNotifications];
        } else {
            NSLog(@"Critical Notifications disabled");
        }
    }];
    NSLog(@"App started");
    
}

- (void)application:(UIApplication *)application didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken {
    PushPlugin *pushHandler = [self getCommandInstance:@"PushNotification"];
    [pushHandler didRegisterForRemoteNotificationsWithDeviceToken:deviceToken];
}

- (void)application:(UIApplication *)application didFailToRegisterForRemoteNotificationsWithError:(NSError *)error {
    PushPlugin *pushHandler = [self getCommandInstance:@"PushNotification"];
    [pushHandler didFailToRegisterForRemoteNotificationsWithError:error];
}

- (void)application:(UIApplication *)application didReceiveRemoteNotification:(NSDictionary *)userInfo fetchCompletionHandler:(void (^)(UIBackgroundFetchResult))completionHandler {
    NSLog(@"didReceiveNotification with fetchCompletionHandler");

    // app is in the background or inactive, so only call notification callback if this is a silent push
    if (application.applicationState != UIApplicationStateActive) {

        NSLog(@"app in-active");

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
            [pushHandler notificationReceived];
        } else {
            NSLog(@"just put it in the shade");
            //save it for later
            self.launchNotification = userInfo;
            completionHandler(UIBackgroundFetchResultNewData);
        }

    } else {
        completionHandler(UIBackgroundFetchResultNoData);
    }
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
        [[UIApplication sharedApplication] setApplicationIconBadgeNumber:0];
    }

    UIApplication *application = notification.object;

    PushPlugin *pushHandler = [self getCommandInstance:@"PushNotification"];
    if (pushHandler.clearBadge) {
        NSLog(@"PushPlugin clearing badge");
        //zero badge
        application.applicationIconBadgeNumber = 0;
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

    [[NSNotificationCenter defaultCenter] postNotificationName:pushPluginApplicationDidBecomeActiveNotification object:nil];
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions options))completionHandler
{
    NSLog( @"NotificationCenter Handle push from foreground" );
    // custom code to handle push while app is in the foreground
    PushPlugin *pushHandler = [self getCommandInstance:@"PushNotification"];
    pushHandler.notificationMessage = notification.request.content.userInfo;
    pushHandler.isInline = YES;
    [pushHandler notificationReceived];

    // Display the notification on the shade including the sound and badge number contained in the push notification
    completionHandler(UNNotificationPresentationOptionAlert | UNNotificationPresentationOptionSound | UNNotificationPresentationOptionBadge);
}

// Method called when a push notification is pressed to let your app know which action was selected by the user for a given notification.
- (void) userNotificationCenter:(UNUserNotificationCenter *)center didReceiveNotificationResponse:(UNNotificationResponse *)response withCompletionHandler:(void(^)())completionHandler{
    
    // Get the data associated of the pressed notification.
    NSDictionary *userInfo = response.notification.request.content.userInfo;

    // Since this logic can run in a coldstart situation (when the app is closed and the OS opens it because a notification was pressed),
    // we need to check if the Cordova plugin is ready to be invoked to send the data to the CORES Mobile JS logic.
    if([self.coldstart boolValue] == YES){
        
        // Create a timer object to check if the plugin is ready to be invoked, checking every second if that is ready.
        checkPluginReadyTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                                 target:self
                                                               selector:@selector(onPluginReady:)
                                                               userInfo:userInfo
                                                                repeats:YES];
        
    } else {
        
        // The app is in foreground or background, so we can immediately send the data of the pressed notification to the CORES Mobile JS logic.
        PushPlugin *pushHandler = [self getCommandInstance:@"PushNotification"];
        [self sendResponseDataOfPressedNotification : userInfo : pushHandler];
        
    }

    completionHandler(UNNotificationPresentationOptionAlert | UNNotificationPresentationOptionSound | UNNotificationPresentationOptionBadge);
    
}

// Method invoked to send the data of the pressed notification to the Cordova Push plugin that will be handled by the CORES Mobile JS logic.
- (void) sendResponseDataOfPressedNotification: (NSDictionary *)userInfo : (PushPlugin *) pushHandler {
    
    NSLog(@"Data from notification %@",userInfo);
    
    // Check if the notification was sent by the APNS (triggered by the CORES API) or it is a local push notification created by us to let the user open all notifications ("open all" notification).
    if ( [userInfo objectForKey:@"coresPayload"] ) {
        
        // Prepare the data that will be validated in CORES Mobile and send it.
        pushHandler.notificationMessage = userInfo;
        pushHandler.isTapped = YES;
        pushHandler.notificationIDsToOpen = @"";
        pushHandler.notificationsGroupedContentList = @"";
        pushHandler.coldstart = [self.coldstart boolValue];
        [pushHandler notificationReceived];
        
    } else {
    
        // This is a local push notification.
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
            
            // Prepare the data to send the notification data to the app.
            pushHandler.isTapped = YES;
            pushHandler.coldstart = [self.coldstart boolValue];
            pushHandler.notificationIDsToOpen = notificationsToOpen;
            pushHandler.notificationsGroupedContentList = @"YES";
            [pushHandler notificationReceived];

        }];
        
    }

}

// Method invoked to verify if the Cordova Push plugin is ready to be used before to send data to the CORES Mobile JS logic.
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

// General listener invoked when a notification is received on the phone, no matter the app status (foreground, backgroubd or stand by).
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
didReceiveNotificationResponse:(UNNotificationResponse *)response
         withCompletionHandler:(void(^)(void))completionHandler
{
    NSLog(@"Push Plugin didReceiveNotificationResponse: actionIdentifier %@, notification: %@", response.actionIdentifier,
          response.notification.request.content.userInfo);
    NSMutableDictionary *userInfo = [response.notification.request.content.userInfo mutableCopy];
    [userInfo setObject:response.actionIdentifier forKey:@"actionCallback"];
    NSLog(@"Push Plugin userInfo %@", userInfo);

    switch ([UIApplication sharedApplication].applicationState) {
        case UIApplicationStateActive:
        {
            PushPlugin *pushHandler = [self getCommandInstance:@"PushNotification"];
            pushHandler.notificationMessage = userInfo;
            pushHandler.isInline = NO;
            pushHandler.isTapped = NO;
            [pushHandler notificationReceived];
            completionHandler();
            break;
        }
        case UIApplicationStateInactive:
        {
            NSLog(@"coldstart");
            self.launchNotification = response.notification.request.content.userInfo;
            self.coldstart = [NSNumber numberWithBool:YES];
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

        // Since iOS will automatically group the notifications, we need to display a local push notification that will help us to open all notification
        // at the same time in the "Notification Viewer" of the CORES Mobile app.
        // But only if there are 1+ notifications in the Notification Center of the phone.
        [self displayOpenAllLocalNotification];
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
