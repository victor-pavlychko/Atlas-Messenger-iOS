//
//  LSAppDelegate.m
//  LayerSample
//
//  Created by Kevin Coleman on 6/10/14.
//  Copyright (c) 2014 Layer, Inc. All rights reserved.
//

#import <LayerKit/LayerKit.h>
#import "LSAppDelegate.h"
#import "LSUIConversationListViewController.h"
#import "LSAPIManager.h"
#import "LSUtilities.h"
#import "LYRUIConstants.h"
#import <Crashlytics/Crashlytics.h>
#import <HockeySDK/HockeySDK.h>
#import "LSAuthenticationTableViewController.h"
#import "LSSplashView.h"
#import "LSLocalNotificationUtilities.h"

extern void LYRSetLogLevelFromEnvironment();

@interface LSAppDelegate ()

@property (nonatomic) UINavigationController *navigationController;
@property (nonatomic) UINavigationController *authenticatedNavigationController;
@property (nonatomic) LSAuthenticationTableViewController *authenticationViewController;
@property (nonatomic) LSSplashView *splashView;
@property (nonatomic) LSEnvironment environment;
@property (nonatomic) LSLocalNotificationUtilities *localNotificationUtilities;

@end

@implementation LSAppDelegate

@synthesize window;

// Fake Commit to build an app
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    // Setup environment configuration
    self.environment = LYRUIDevelopment;
    LYRSetLogLevelFromEnvironment();
    
    // Configure Layer Base URL
    NSString *currentConfigURL = [[NSUserDefaults standardUserDefaults] objectForKey:@"LAYER_CONFIGURATION_URL"];
    if (![currentConfigURL isEqualToString:LSLayerConfigurationURL(self.environment)]) {
        [[NSUserDefaults standardUserDefaults] setObject:LSLayerConfigurationURL(self.environment) forKey:@"LAYER_CONFIGURATION_URL"];
    }
    
    // Configure application controllers
    self.applicationController = [LSApplicationController controllerWithBaseURL:LSRailsBaseURL()
                                                                    layerClient:[LYRClient clientWithAppID:LSLayerAppID(self.environment)]
                                                             persistenceManager:LSPersitenceManager()];
    
    self.localNotificationUtilities = [LSLocalNotificationUtilities initWithLayerClient:self.applicationController.layerClient];
    
    // Setup notifications
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(userDidAuthenticateNotification:)
                                                 name:LSUserDidAuthenticateNotification
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(userDidDeauthenticateNotification:)
                                                 name:LSUserDidDeauthenticateNotification
                                               object:nil];
    
    // Connect Layer SDK
    [self.applicationController.layerClient connectWithCompletion:^(BOOL success, NSError *error) {
        if (error) {
            NSLog(@"Error connecting Layer: %@", error);
        } else {
            NSLog(@"Layer Client is connected");
            if (self.applicationController.layerClient.authenticatedUserID) {
                [self resumeSession];
                [self presentConversationsListViewController];
            }
        }
        [self removeSplashView];
    }];
    
    // Setup application
    [self setRootViewController];
    [self registerForRemoteNotifications:application];
    
    // Setup SDKs
    [self initializeCrashlytics];
    //[self initializeHockeyApp];
    
    // Setup Screenshot Listener for Bugs
    [self listenForScreenShots];

    // Configure Sample App UI Appearance
    [self configureGlobalUserInterfaceAttributes];
    
    // ConversationListViewController Config
    _cellClass = [LYRUIConversationTableViewCell class];
    _rowHeight = 72;
    _allowsEditing = YES;
    _displaysConversationImage = NO;
    _displaysSettingsButton = YES;
    
    return YES;
}

- (void)applicationWillEnterForeground:(UIApplication *)application
{
    [self.localNotificationUtilities setShouldListenForChanges:NO];
    [self resumeSession];
    [self loadContacts];
}

- (void)applicationWillResignActive:(UIApplication *)application
{
    [self getUnreadMessageCount];
    if (self.applicationController.shouldDisplayLocalNotifications) {
        [self.localNotificationUtilities setShouldListenForChanges:YES];
    }
}

- (void)registerForRemoteNotifications:(UIApplication *)application
{
    // Declaring that I want to recieve push!
    if ([application respondsToSelector:@selector(registerForRemoteNotifications)]) {
        UIUserNotificationSettings *notificationSettings = [UIUserNotificationSettings settingsForTypes:UIUserNotificationTypeAlert | UIUserNotificationTypeBadge | UIUserNotificationTypeSound
                                                                                             categories:nil];
        [application registerUserNotificationSettings:notificationSettings];
        [application registerForRemoteNotifications];
    } else {
        [application registerForRemoteNotificationTypes:UIRemoteNotificationTypeAlert | UIRemoteNotificationTypeSound | UIRemoteNotificationTypeBadge];
    }
}


- (void)setRootViewController
{
    self.authenticationViewController = [LSAuthenticationTableViewController new];
    self.authenticationViewController.applicationController = self.applicationController;
    
    self.navigationController = [[UINavigationController alloc] initWithRootViewController:self.authenticationViewController];
    self.navigationController.navigationBarHidden = TRUE;
    self.navigationController.navigationBar.barTintColor = LSLighGrayColor();
    self.navigationController.navigationBar.tintColor = LSBlueColor();
    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    self.window.rootViewController = self.navigationController;
    [self.window makeKeyAndVisible];
    
    [self addSplashView];
}

- (void)resumeSession
{
    LSSession *session = [self.applicationController.persistenceManager persistedSessionWithError:nil];
    [self.applicationController.APIManager resumeSession:session error:nil];
}

- (void)initializeCrashlytics
{
    [Crashlytics startWithAPIKey:@"0a0f48084316c34c98d99db32b6d9f9a93416892"];
    [Crashlytics setObjectValue:LSLayerConfigurationURL(self.environment) forKey:@"ConfigurationURL"];
    [Crashlytics setObjectValue:LSLayerAppID(self.environment) forKey:@"AppID"];
}

- (void)initializeHockeyApp
{
    [[BITHockeyManager sharedHockeyManager] configureWithIdentifier:@"1681559bb4230a669d8b057adf8e4ae3"];
    [BITHockeyManager sharedHockeyManager].disableCrashManager = YES;
    [[BITHockeyManager sharedHockeyManager] startManager];
    [[BITHockeyManager sharedHockeyManager].authenticator authenticateInstallation];
}

- (void)updateCrashlyticsWithUser:(LSUser *)authenticatedUser
{
    // Note: If authenticatedUser is nil, this will nil out everything which is what we want.
    [Crashlytics setUserName:authenticatedUser.fullName];
    [Crashlytics setUserEmail:authenticatedUser.email];
    [Crashlytics setUserIdentifier:authenticatedUser.userID];
}

- (void)listenForScreenShots
{
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(screenshotTaken:)
                                                 name:UIApplicationUserDidTakeScreenshotNotification
                                               object:nil];
}

- (void)application:(UIApplication *)application didFailToRegisterForRemoteNotificationsWithError:(NSError *)error
{
    NSLog(@"Application failed to register for remote notifications with error %@", error);
}

- (void)application:(UIApplication *)application didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken
{
    self.applicationController.deviceToken = deviceToken;
    NSError *error;
    BOOL success = [self.applicationController.layerClient updateRemoteNotificationDeviceToken:deviceToken error:&error];
    if (success) {
        NSLog(@"Application did register for remote notifications");
    } else {
        NSLog(@"Error updating Layer device token for push:%@", error);
        UIAlertView *alertView = [[UIAlertView alloc] initWithTitle:@"Updating Device Token Failed" message:[error localizedDescription] delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil];
        [alertView show];
    }
}

- (void)application:(UIApplication *)application didReceiveRemoteNotification:(NSDictionary *)userInfo fetchCompletionHandler:(void (^)(UIBackgroundFetchResult))completionHandler
{
    // Increment badge count if a message
    if ([[userInfo valueForKeyPath:@"aps.content-available"] integerValue] == 0) {
        NSInteger badgeNumber = [[UIApplication sharedApplication] applicationIconBadgeNumber];
        [[UIApplication sharedApplication] setApplicationIconBadgeNumber:badgeNumber + 1];
    }
    
    __block LYRMessage *message = [self messageFromRemoteNotification:userInfo];
    if (application.applicationState == UIApplicationStateInactive && message) {
        [self navigateToConversationViewForMessage:message];
    }
    
    BOOL success = [self.applicationController.layerClient synchronizeWithRemoteNotification:userInfo completion:^(UIBackgroundFetchResult fetchResult, NSError *error) {
        if (fetchResult == UIBackgroundFetchResultFailed) {
            NSLog(@"Failed processing remote notification: %@", error);
        }
        
        // Try navigating once the synchronization completed
        if (application.applicationState == UIApplicationStateInactive && !message) {
            message = [self messageFromRemoteNotification:userInfo];
            [self navigateToConversationViewForMessage:message];
        }
        completionHandler(fetchResult);
    }];
    
    if (!success) {
        completionHandler(UIBackgroundFetchResultNoData);
    }
}

- (LYRMessage *)messageFromRemoteNotification:(NSDictionary *)remoteNotification
{
    // Fetch message object from LayerKit
    NSURL *messageURL = [NSURL URLWithString:[remoteNotification valueForKeyPath:@"layer.event_url"]];
    NSSet *messages = [self.applicationController.layerClient messagesForIdentifiers:[NSSet setWithObject:messageURL]];
    return [[messages allObjects] firstObject];
}

- (void)navigateToConversationViewForMessage:(LYRMessage *)message
{
    UINavigationController *controller = (UINavigationController *)self.window.rootViewController.presentedViewController;
    LSUIConversationListViewController *conversationListViewController = [controller.viewControllers objectAtIndex:0];
    [conversationListViewController selectConversation:message.conversation];
}

- (void)userDidAuthenticateNotification:(NSNotification *)notification
{
    NSError *error = nil;
    LSSession *session = self.applicationController.APIManager.authenticatedSession;
    BOOL success = [self.applicationController.persistenceManager persistSession:session error:&error];
    if (success) {
        NSLog(@"Persisted authenticated user session: %@", session);
    } else {
        NSLog(@"Failed persisting authenticated user: %@. Error: %@", session, error);
        LSAlertWithError(error);
    }
    
    [self updateCrashlyticsWithUser:session.user];
    
    [self loadContacts];
    [self presentConversationsListViewController];
}

- (void)userDidDeauthenticateNotification:(NSNotification *)notification
{
    NSError *error = nil;
    BOOL success = [self.applicationController.persistenceManager persistSession:nil error:&error];
    
    // nil out all crashlytics user information.
    [self updateCrashlyticsWithUser:nil];
    
    if (success) {
        NSLog(@"Cleared persisted user session");
    } else {
        NSLog(@"Failed clearing persistent user session: %@", error);
        LSAlertWithError(error);
    }
    
    [self.navigationController dismissViewControllerAnimated:YES completion:^{
        self.viewController = nil;
        self.authenticatedNavigationController = nil;
    }];
}

- (void)loadContacts
{
    [self.applicationController.APIManager loadContactsWithCompletion:^(NSSet *contacts, NSError *error) {
        if (contacts) {
            NSError *persistenceError = nil;
            BOOL success = [self.applicationController.persistenceManager persistUsers:contacts error:&persistenceError];
            if (success) {
                [[NSNotificationCenter defaultCenter] postNotificationName:@"contactsPersited" object:nil];
            } else {
                LSAlertWithError(persistenceError);
            }
        } else {
            LSAlertWithError(error);
        }
    }];

}

- (void)presentConversationsListViewController
{
    if (self.window.rootViewController.presentedViewController) {
        [self removeSplashView];
        return;
    }
    self.viewController = [LSUIConversationListViewController conversationListViewControllerWithLayerClient:self.applicationController.layerClient];
    self.viewController.applicationController = self.applicationController;
    self.viewController.displaysConversationImage = self.displaysConversationImage;
    self.viewController.cellClass = self.cellClass;
    self.viewController.rowHeight = self.rowHeight;
    self.viewController.allowsEditing = self.allowsEditing;
    self.viewController.shouldDisplaySettingsItem = self.displaysSettingsButton;
    
    self.authenticatedNavigationController = [[UINavigationController alloc] initWithRootViewController:self.viewController];
    [self.navigationController presentViewController:self.authenticatedNavigationController animated:YES completion:^{
        [self.authenticationViewController resetState];
        [self removeSplashView];
    }];
}
- (void)addSplashView
{
    if (!self.splashView) {
        self.splashView = [[LSSplashView alloc] initWithFrame:self.window.bounds];
    }
    [self.window addSubview:self.splashView];
}

- (void)removeSplashView
{
    [UIView animateWithDuration:0.5 animations:^{
        self.splashView.alpha = 0.0;
    } completion:^(BOOL finished) {
        [self.splashView removeFromSuperview];
        self.splashView = nil;
    }];
}

- (void)configureGlobalUserInterfaceAttributes
{
    [[UINavigationBar appearance] setTintColor:LSBlueColor()];
    [[UINavigationBar appearance] setBarTintColor:LSLighGrayColor()];
    [[UINavigationBar appearance] setTitleTextAttributes:@{NSFontAttributeName: LSBoldFont(18)}];
    
    [[UIBarButtonItem appearanceWhenContainedIn:[UINavigationBar class], nil] setTitleTextAttributes:@{NSFontAttributeName : LSMediumFont(16)} forState:UIControlStateNormal];
    [[UIBarButtonItem appearanceWhenContainedIn:[UINavigationBar class], nil] setTintColor:LSBlueColor()];

}

- (void)screenshotTaken:(NSNotification *)notification
{
    
}

- (void)getUnreadMessageCount
{
    __block NSUInteger unreadMessageCount = 0;
    __block NSString *userID = self.applicationController.layerClient.authenticatedUserID;
    NSSet *conversations = [self.applicationController.layerClient conversationsForIdentifiers:nil];
    for (LYRConversation *conversation in conversations) {
        NSOrderedSet *messages = [self.applicationController.layerClient messagesForConversation:conversation];
        for (LYRMessage *message in messages) {
            LYRRecipientStatus status = [[message.recipientStatusByUserID objectForKey:userID] integerValue];
            //NSLog(@"Status: %ld", status);
            switch (status) {
                case LYRRecipientStatusDelivered:
                    unreadMessageCount += 1;
                    break;
                    
                default:
                    break;
            }
        }
    }
    [[UIApplication sharedApplication] setApplicationIconBadgeNumber:unreadMessageCount];
}

@end
