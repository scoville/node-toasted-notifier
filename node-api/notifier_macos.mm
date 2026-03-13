#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>

#include <napi.h>
#include <atomic>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>

@interface NTNNotificationDelegate : NSObject <UNUserNotificationCenterDelegate>
@end

namespace {

struct NotificationContext {
  Napi::ThreadSafeFunction tsfn;
  std::atomic_bool completed{false};
};

std::mutex g_contexts_mutex;
std::unordered_map<std::string, std::shared_ptr<NotificationContext>>
    g_contexts;

NTNNotificationDelegate* g_delegate = nil;

static bool IsRunningInAppBundle() {
  NSString* bundle_path = [[NSBundle mainBundle] bundlePath];
  if (!bundle_path || [bundle_path length] == 0) {
    // Probably running in Node.js.
    return false;
  }

  // Probably running in Electron.
  NSString* bundle_id = [[NSBundle mainBundle] bundleIdentifier];
  if (bundle_id && [bundle_id length] > 0) {
    // In debug builds: "com.github.Electron"
    NSLog(@"toasted-notifier bundle id: %@", bundle_id);
  }
  return [[bundle_path pathExtension] isEqualToString:@"app"];
}

static void EnsureDelegateInstalled() {
  if (!IsRunningInAppBundle()) {
    return;
  }
  if (!g_delegate) {
    g_delegate = [NTNNotificationDelegate new];
  }
  UNUserNotificationCenter* center =
      [UNUserNotificationCenter currentNotificationCenter];
  center.delegate = g_delegate;
}

static std::shared_ptr<NotificationContext> TakePendingContext(
    const std::string& id) {
  std::lock_guard<std::mutex> lock(g_contexts_mutex);
  auto it = g_contexts.find(id);
  if (it == g_contexts.end()) {
    return nullptr;
  }

  std::shared_ptr<NotificationContext> ctx = it->second;
  if (ctx->completed.exchange(true)) {
    g_contexts.erase(it);
    return nullptr;
  }

  g_contexts.erase(it);
  return ctx;
}

static bool TryCompleteWithActivation(const std::string& id,
                                      const std::string& activation_value) {
  std::shared_ptr<NotificationContext> ctx = TakePendingContext(id);
  if (!ctx) {
    return false;
  }

  ctx->tsfn.BlockingCall([activation_value](Napi::Env env, Napi::Function cb) {
    Napi::Value err = env.Null();
    Napi::Value response = env.Null();
    Napi::Object metadata = Napi::Object::New(env);
    metadata.Set("activationValue", Napi::String::New(env, activation_value));
    cb.Call({err, response, metadata});
  });
  ctx->tsfn.Release();
  return true;
}

static bool TryCompleteWithError(const std::string& id,
                                 const std::string& message) {
  std::shared_ptr<NotificationContext> ctx = TakePendingContext(id);
  if (!ctx) {
    return false;
  }

  ctx->tsfn.BlockingCall([message](Napi::Env env, Napi::Function cb) {
    Napi::Value err = Napi::Error::New(env, message).Value();
    cb.Call({err, env.Null(), env.Null()});
  });
  ctx->tsfn.Release();
  return true;
}

static std::string NewNotificationId() {
  NSString* uuid = [[NSUUID UUID] UUIDString];
  return std::string([uuid UTF8String]);
}

static std::string MakeActionIdentifier(const std::string& title) {
  return std::string("action:") + title;
}

static void ScheduleTimeout(std::string notify_id,
                            UNUserNotificationCenter* center,
                            double timeout_seconds) {
  if (timeout_seconds <= 0) {
    return;
  }

  NSString* request_id = [NSString stringWithUTF8String:notify_id.c_str()];
  std::string timeout_notify_id = std::move(notify_id);
  dispatch_time_t when = dispatch_time(
      DISPATCH_TIME_NOW, (int64_t)(timeout_seconds * NSEC_PER_SEC));
  dispatch_after(when, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
    if (TryCompleteWithActivation(timeout_notify_id, "timeout")) {
      NSArray* identifiers = @[ request_id ];
      [center removeDeliveredNotificationsWithIdentifiers:identifiers];
      [center removePendingNotificationRequestsWithIdentifiers:identifiers];
    }
  });
}

}  // namespace

@implementation NTNNotificationDelegate

- (void)userNotificationCenter:(UNUserNotificationCenter*)center
       willPresentNotification:(UNNotification*)notification
         withCompletionHandler:
             (void (^)(UNNotificationPresentationOptions options))
                 completionHandler {
  completionHandler(UNNotificationPresentationOptionBanner |
                    UNNotificationPresentationOptionSound);
}

- (void)userNotificationCenter:(UNUserNotificationCenter*)center
    didReceiveNotificationResponse:(UNNotificationResponse*)response
             withCompletionHandler:(void (^)(void))completionHandler {
  NSString* request_id = response.notification.request.identifier;
  if (!request_id) {
    completionHandler();
    return;
  }

  std::string activation_value = "activate";
  NSString* action_id = response.actionIdentifier;
  if ([action_id isEqualToString:UNNotificationDismissActionIdentifier]) {
    activation_value = "dismiss";
  } else if ([action_id
                 isEqualToString:UNNotificationDefaultActionIdentifier]) {
    activation_value = "activate";
  } else {
    activation_value = std::string([action_id UTF8String]);
    const std::string prefix = "action:";
    if (activation_value.rfind(prefix, 0) == 0) {
      activation_value = activation_value.substr(prefix.size());
    }
  }

  TryCompleteWithActivation(std::string([request_id UTF8String]),
                            activation_value);
  completionHandler();
}

@end

static Napi::Value Notify(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();

  if (info.Length() < 1 || !info[0].IsObject()) {
    Napi::TypeError::New(env, "First argument must be an options object")
        .ThrowAsJavaScriptException();
    return env.Null();
  }

  Napi::Object options = info[0].As<Napi::Object>();
  Napi::Function callback;
  bool has_callback = false;

  if (info.Length() >= 2) {
    if (!info[1].IsFunction()) {
      Napi::TypeError::New(env, "Second argument must be a function")
          .ThrowAsJavaScriptException();
      return env.Null();
    }
    callback = info[1].As<Napi::Function>();
    has_callback = true;
  }

  std::string title = "toasted-notifier";
  if (options.Has("title") && options.Get("title").IsString()) {
    title = options.Get("title").As<Napi::String>().Utf8Value();
  }

  std::string message;
  if (options.Has("message") && options.Get("message").IsString()) {
    message = options.Get("message").As<Napi::String>().Utf8Value();
  }

  if (message.empty()) {
    Napi::TypeError::New(env, "Expected non-empty message option")
        .ThrowAsJavaScriptException();
    return env.Null();
  }

  std::string action_title;
  if (options.Has("actions")) {
    Napi::Value actions = options.Get("actions");
    if (actions.IsString()) {
      action_title = actions.As<Napi::String>().Utf8Value();
    } else if (actions.IsArray()) {
      Napi::Array arr = actions.As<Napi::Array>();
      if (arr.Length() > 0 && arr.Get((uint32_t)0).IsString()) {
        action_title = arr.Get((uint32_t)0).As<Napi::String>().Utf8Value();
      }
    }
  }

  double timeout_seconds = -1;
  if (options.Has("timeout") && options.Get("timeout").IsNumber()) {
    timeout_seconds = options.Get("timeout").As<Napi::Number>().DoubleValue();
  }

  if (!IsRunningInAppBundle()) {
    const std::string message =
        "UNUserNotificationCenter requires an app bundle (Electron app).";
    if (has_callback) {
      Napi::ThreadSafeFunction tsfn =
          Napi::ThreadSafeFunction::New(env, callback, "notify_callback", 0, 1);
      tsfn.BlockingCall([message](Napi::Env env, Napi::Function cb) {
        Napi::Value err = Napi::Error::New(env, message).Value();
        cb.Call({err, env.Null(), env.Null()});
      });
      tsfn.Release();
      return env.Undefined();
    }
    Napi::Error::New(env, message).ThrowAsJavaScriptException();
    return env.Null();
  }

  EnsureDelegateInstalled();
  UNUserNotificationCenter* center =
      [UNUserNotificationCenter currentNotificationCenter];

  std::string notify_id = NewNotificationId();
  NSString* request_id = [NSString stringWithUTF8String:notify_id.c_str()];

  if (has_callback) {
    auto ctx = std::make_shared<NotificationContext>(NotificationContext{
        Napi::ThreadSafeFunction::New(env, callback, "notify_callback", 0, 1)});
    std::lock_guard<std::mutex> lock(g_contexts_mutex);
    g_contexts[notify_id] = ctx;
  }

  UNMutableNotificationContent* content = [UNMutableNotificationContent new];
  content.title = [NSString stringWithUTF8String:title.c_str()];
  content.body = [NSString stringWithUTF8String:message.c_str()];

  if (!action_title.empty()) {
    std::string action_id = MakeActionIdentifier(action_title);
    NSString* action_identifier =
        [NSString stringWithUTF8String:action_id.c_str()];
    NSString* action_label =
        [NSString stringWithUTF8String:action_title.c_str()];
    UNNotificationAction* action = [UNNotificationAction
        actionWithIdentifier:action_identifier
                       title:action_label
                     options:UNNotificationActionOptionForeground];
    NSString* category_id =
        [NSString stringWithFormat:@"toasted_%@", request_id];
    UNNotificationCategory* category = [UNNotificationCategory
        categoryWithIdentifier:category_id
                       actions:@[ action ]
             intentIdentifiers:@[]
                       options:UNNotificationCategoryOptionNone];
    [center setNotificationCategories:[NSSet setWithObject:category]];
    content.categoryIdentifier = category_id;
  }

  UNNotificationRequest* request =
      [UNNotificationRequest requestWithIdentifier:request_id
                                           content:content
                                           trigger:nil];

  ScheduleTimeout(notify_id, center, timeout_seconds);

  [center getNotificationSettingsWithCompletionHandler:^(
              UNNotificationSettings* settings) {
    if (settings.authorizationStatus == UNAuthorizationStatusNotDetermined) {
      [center
          requestAuthorizationWithOptions:(UNAuthorizationOptionAlert |
                                           UNAuthorizationOptionSound |
                                           UNAuthorizationOptionBadge)
                        completionHandler:^(BOOL granted, NSError* error) {
                          if (error) {
                            TryCompleteWithError(
                                notify_id,
                                std::string(
                                    [[error localizedDescription] UTF8String]));
                            return;
                          }
                          if (!granted) {
                            TryCompleteWithError(
                                notify_id,
                                "Notification permission not granted");
                            return;
                          }
                          [center addNotificationRequest:request
                                   withCompletionHandler:^(NSError* add_error) {
                                     if (add_error) {
                                       TryCompleteWithError(
                                           notify_id,
                                           std::string(
                                               [[add_error localizedDescription]
                                                   UTF8String]));
                                     }
                                   }];
                        }];
      return;
    }

    if (settings.authorizationStatus == UNAuthorizationStatusDenied) {
      TryCompleteWithError(notify_id, "Notification permission denied");
      return;
    }

    [center addNotificationRequest:request
             withCompletionHandler:^(NSError* add_error) {
               if (add_error) {
                 TryCompleteWithError(
                     notify_id, std::string([[add_error localizedDescription]
                                    UTF8String]));
               }
             }];
  }];

  return env.Undefined();
}

Napi::Object Init(Napi::Env env, Napi::Object exports) {
  exports.Set(Napi::String::New(env, "notify"),
              Napi::Function::New(env, Notify));
  return exports;
}

NODE_API_MODULE(notifier, Init)
