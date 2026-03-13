#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <UserNotifications/UserNotifications.h>

#include <napi.h>
#include <algorithm>
#include <atomic>
#include <cctype>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

@interface UNUserNotificationCenter (NTNDelegateProxy)
- (void)ntn_setDelegate:(id<UNUserNotificationCenterDelegate>)delegate;
@end

@interface NTNNotificationDelegate : NSObject <UNUserNotificationCenterDelegate> {
 @private
  id<UNUserNotificationCenterDelegate> downstream_delegate_;
}
@property(nonatomic, assign) id<UNUserNotificationCenterDelegate> downstreamDelegate;
@end

namespace {

static bool OpenURLString(const std::string& value);
static bool TryCompleteWithActivation(const std::string& id,
                                      const std::string& activation_type,
                                      const std::optional<std::string>&
                                          activation_value = std::nullopt);

struct NotificationContext {
  Napi::ThreadSafeFunction tsfn;
  std::atomic_bool completed{false};
  std::string open_url;
  std::string delivered_at;

  explicit NotificationContext(Napi::ThreadSafeFunction callback_tsfn,
                               std::string open_url_value = std::string())
      : tsfn(std::move(callback_tsfn)), open_url(std::move(open_url_value)) {}

  NotificationContext(const NotificationContext&) = delete;
  NotificationContext& operator=(const NotificationContext&) = delete;
};

std::mutex g_contexts_mutex;
std::unordered_map<std::string, std::shared_ptr<NotificationContext>>
    g_contexts;

NTNNotificationDelegate* g_delegate = nil;
dispatch_once_t g_delegate_swizzle_once;

static NSString* const kNTNManagedNotificationKey = @"toastedNotifierManaged";
static NSString* const kNTNOpenURLKey = @"open";
static NSString* const kNTNReplyKey = @"reply";

static bool IsManagedUserInfo(NSDictionary* user_info) {
  if (!user_info) {
    return false;
  }

  id marker = user_info[kNTNManagedNotificationKey];
  return marker && [marker respondsToSelector:@selector(boolValue)] &&
         [marker boolValue];
}

static bool IsManagedNotification(UNNotification* notification) {
  if (!notification) {
    return false;
  }

  return IsManagedUserInfo(notification.request.content.userInfo);
}

static void HandleManagedNotificationResponse(UNNotificationResponse* response) {
  NSString* request_id = response.notification.request.identifier;
  if (!request_id) {
    return;
  }

  std::string activation_type = "activate";
  std::optional<std::string> activation_value = std::nullopt;
  NSString* action_id = response.actionIdentifier;
  if ([action_id isEqualToString:UNNotificationDismissActionIdentifier]) {
    activation_type = "dismiss";
  } else if ([action_id
                 isEqualToString:UNNotificationDefaultActionIdentifier]) {
    activation_type = "activate";
  } else if ([response isKindOfClass:[UNTextInputNotificationResponse class]]) {
    activation_type = "replied";
    NSString* user_text =
        [(UNTextInputNotificationResponse*)response userText];
    if (user_text && [user_text length] > 0) {
      activation_value = std::string([user_text UTF8String]);
    }
  } else {
    activation_type = "activate";
    std::string value = std::string([action_id UTF8String]);
    const std::string prefix = "action:";
    if (value.rfind(prefix, 0) == 0) {
      value = value.substr(prefix.size());
    }
    activation_value = value;
  }

  std::string request_id_value([request_id UTF8String]);
  if (TryCompleteWithActivation(request_id_value, activation_type,
                                activation_value)) {
    return;
  }

  if (activation_type == "activate" && !activation_value.has_value()) {
    NSDictionary* user_info = response.notification.request.content.userInfo;
    NSString* open_url = user_info[kNTNOpenURLKey];
    if (open_url && [open_url isKindOfClass:[NSString class]]) {
      OpenURLString(std::string([open_url UTF8String]));
    }
  }
}

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

static std::string DateToString(NSDate* date) {
  if (!date) {
    return std::string();
  }

  return std::string([[date description] UTF8String]);
}

static std::string SanitizeResponseValue(const std::string& activation_type) {
  if (activation_type.empty()) {
    return std::string();
  }

  std::string response = activation_type;
  std::transform(response.begin(), response.end(), response.begin(),
                 [](unsigned char ch) { return std::tolower(ch); });

  auto first = response.find_first_not_of(" \t\n\r");
  if (first == std::string::npos) {
    return std::string();
  }
  auto last = response.find_last_not_of(" \t\n\r");
  response = response.substr(first, last - first + 1);

  if (response == "clicked") {
    return "activate";
  }
  if (response == "timedout") {
    return "timeout";
  }

  return response;
}

static bool IsBuiltInMacSoundName(const std::string& sound_name) {
  static const std::unordered_set<std::string> sounds = {
      "Basso",     "Blow",     "Bottle",   "Frog",      "Funk",
      "Glass",     "Hero",     "Morse",    "Ping",      "Pop",
      "Purr",      "Sosumi",   "Submarine", "Tink"};
  return sounds.find(sound_name) != sounds.end();
}

static NSURL* URLFromStringValue(const std::string& value) {
  if (value.empty()) {
    return nil;
  }

  NSString* string_value = [NSString stringWithUTF8String:value.c_str()];
  NSURL* url = [NSURL URLWithString:string_value];
  if (url && url.scheme) {
    return url;
  }

  return [NSURL fileURLWithPath:string_value];
}

static bool OpenURLString(const std::string& value) {
  NSURL* url = URLFromStringValue(value);
  if (!url) {
    return false;
  }

  return [[NSWorkspace sharedWorkspace] openURL:url];
}

static std::shared_ptr<NotificationContext> FindPendingContext(
    const std::string& id) {
  std::lock_guard<std::mutex> lock(g_contexts_mutex);
  auto it = g_contexts.find(id);
  if (it == g_contexts.end()) {
    return nullptr;
  }
  return it->second;
}

static void MarkDelivered(const std::string& id) {
  std::shared_ptr<NotificationContext> ctx = FindPendingContext(id);
  if (!ctx) {
    return;
  }

  ctx->delivered_at = DateToString([NSDate date]);
}

static bool CompleteContext(const std::shared_ptr<NotificationContext>& ctx,
                            const std::string& activation_type,
                            const std::optional<std::string>& activation_value) {
  const std::string response_value = SanitizeResponseValue(activation_type);
  const std::string activation_at = DateToString([NSDate date]);
  const std::string delivered_at = ctx->delivered_at;

  ctx->tsfn.BlockingCall([response_value, activation_type, activation_value,
                         activation_at, delivered_at](Napi::Env env,
                                                      Napi::Function cb) {
    Napi::Value err = env.Null();
    Napi::Value response = response_value.empty()
                               ? env.Undefined()
                               : Napi::String::New(env, response_value);
    Napi::Object metadata = Napi::Object::New(env);

    if (!activation_type.empty()) {
      metadata.Set("activationType", Napi::String::New(env, activation_type));
    }
    if (activation_value && !activation_value->empty()) {
      metadata.Set("activationValue",
                   Napi::String::New(env, *activation_value));
    }
    if (!activation_at.empty()) {
      metadata.Set("activationAt", Napi::String::New(env, activation_at));
    }
    if (!delivered_at.empty()) {
      metadata.Set("deliveredAt", Napi::String::New(env, delivered_at));
    }

    cb.Call({err, response, metadata});
  });
  return true;
}

static void EnsureDelegateInstalled() {
  if (!IsRunningInAppBundle()) {
    return;
  }
  if (!g_delegate) {
    g_delegate = [NTNNotificationDelegate new];
  }
  dispatch_once(&g_delegate_swizzle_once, ^{
    Class center_class = [UNUserNotificationCenter class];
    SEL original_selector = @selector(setDelegate:);
    SEL swizzled_selector = @selector(ntn_setDelegate:);
    Method original_method =
        class_getInstanceMethod(center_class, original_selector);
    Method swizzled_method =
        class_getInstanceMethod(center_class, swizzled_selector);
    method_exchangeImplementations(original_method, swizzled_method);
  });

  UNUserNotificationCenter* center =
      [UNUserNotificationCenter currentNotificationCenter];
  id<UNUserNotificationCenterDelegate> current_delegate = center.delegate;
  if (current_delegate && current_delegate != g_delegate) {
    g_delegate.downstreamDelegate = current_delegate;
  }
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
                                      const std::string& activation_type,
                    const std::optional<std::string>&
                      activation_value) {
  std::shared_ptr<NotificationContext> ctx = TakePendingContext(id);
  if (!ctx) {
    return false;
  }

  if (activation_type == "activate" && !activation_value.has_value() &&
      !ctx->open_url.empty()) {
    OpenURLString(ctx->open_url);
  }

  CompleteContext(ctx, activation_type, activation_value);
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
    cb.Call({err, env.Undefined(), env.Undefined()});
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

static void ScheduleTimeout(std::string notify_id, double timeout_seconds) {
  if (timeout_seconds <= 0) {
    return;
  }

  std::string timeout_notify_id = std::move(notify_id);
  dispatch_time_t when = dispatch_time(
      DISPATCH_TIME_NOW, (int64_t)(timeout_seconds * NSEC_PER_SEC));
  dispatch_after(when, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
    TryCompleteWithActivation(timeout_notify_id, "timeout", std::nullopt);
  });
}

}  // namespace

@implementation UNUserNotificationCenter (NTNDelegateProxy)

- (void)ntn_setDelegate:(id<UNUserNotificationCenterDelegate>)delegate {
  if (!g_delegate || delegate == g_delegate) {
    [self ntn_setDelegate:delegate];
    return;
  }

  g_delegate.downstreamDelegate = delegate;
  [self ntn_setDelegate:g_delegate];
}

@end

@implementation NTNNotificationDelegate

- (BOOL)respondsToSelector:(SEL)selector {
  if ([super respondsToSelector:selector]) {
    return YES;
  }

  id<UNUserNotificationCenterDelegate> downstream = self.downstreamDelegate;
  return downstream && [(id)downstream respondsToSelector:selector];
}

- (id)forwardingTargetForSelector:(SEL)selector {
  id<UNUserNotificationCenterDelegate> downstream = self.downstreamDelegate;
  if (downstream && [(id)downstream respondsToSelector:selector]) {
    return downstream;
  }

  return [super forwardingTargetForSelector:selector];
}

- (void)userNotificationCenter:(UNUserNotificationCenter*)center
       willPresentNotification:(UNNotification*)notification
         withCompletionHandler:
             (void (^)(UNNotificationPresentationOptions options))
                 completionHandler {
  id<UNUserNotificationCenterDelegate> downstream = self.downstreamDelegate;
  const bool is_managed = IsManagedNotification(notification);
  UNNotificationPresentationOptions options =
      is_managed ? UNNotificationPresentationOptionSound : 0;
  if (is_managed) {
    if (@available(macOS 11.0, *)) {
      options |= UNNotificationPresentationOptionBanner;
    } else {
      options |= UNNotificationPresentationOptionAlert;
    }
  }

  if (downstream &&
      [(id)downstream
          respondsToSelector:@selector(userNotificationCenter:
                                 willPresentNotification:
                                   withCompletionHandler:)]) {
    [downstream userNotificationCenter:center
               willPresentNotification:notification
                 withCompletionHandler:^(
                     UNNotificationPresentationOptions downstream_options) {
                   completionHandler(downstream_options | options);
                 }];
    return;
  }

  completionHandler(options);
}

- (void)userNotificationCenter:(UNUserNotificationCenter*)center
    didReceiveNotificationResponse:(UNNotificationResponse*)response
             withCompletionHandler:(void (^)(void))completionHandler {
  id<UNUserNotificationCenterDelegate> downstream = self.downstreamDelegate;
  if (IsManagedNotification(response.notification)) {
    HandleManagedNotificationResponse(response);
  }

  if (downstream &&
      [(id)downstream
          respondsToSelector:@selector(userNotificationCenter:
                                 didReceiveNotificationResponse:
                                   withCompletionHandler:)]) {
    [downstream userNotificationCenter:center
          didReceiveNotificationResponse:response
                   withCompletionHandler:completionHandler];
    return;
  }

  completionHandler();
}

@end

static Napi::Value Notify(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();

  Napi::Value options_value = info.Length() >= 1 ? info[0] : env.Undefined();

  if (options_value.IsString()) {
    Napi::Object shorthand = Napi::Object::New(env);
    shorthand.Set("title", Napi::String::New(env, "toasted-notifier"));
    shorthand.Set("message", options_value);
    options_value = shorthand;
  }

  if (info.Length() < 1 || !options_value.IsObject()) {
    Napi::TypeError::New(env, "First argument must be an options object")
        .ThrowAsJavaScriptException();
    return env.Null();
  }

  Napi::Object options = options_value.As<Napi::Object>();
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

  std::string title;
  if (options.Has("title") && options.Get("title").IsString()) {
    title = options.Get("title").As<Napi::String>().Utf8Value();
  }

  std::string subtitle;
  if (options.Has("subtitle") && options.Get("subtitle").IsString()) {
    subtitle = options.Get("subtitle").As<Napi::String>().Utf8Value();
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

  std::vector<std::string> action_titles;
  if (options.Has("actions")) {
    Napi::Value actions = options.Get("actions");
    if (actions.IsString()) {
      action_titles.push_back(actions.As<Napi::String>().Utf8Value());
    } else if (actions.IsArray()) {
      Napi::Array arr = actions.As<Napi::Array>();
      for (uint32_t index = 0; index < arr.Length(); ++index) {
        if (arr.Get(index).IsString()) {
          action_titles.push_back(arr.Get(index).As<Napi::String>().Utf8Value());
        }
      }
    }
  }

  bool reply = false;
  if (options.Has("reply") && options.Get("reply").IsBoolean()) {
    reply = options.Get("reply").As<Napi::Boolean>().Value();
  }

  if (reply && !action_titles.empty()) {
    Napi::TypeError::New(env, "reply cannot be combined with actions")
        .ThrowAsJavaScriptException();
    return env.Null();
  }

  double timeout_seconds = -1;
  if (options.Has("timeout") && options.Get("timeout").IsNumber()) {
    timeout_seconds = options.Get("timeout").As<Napi::Number>().DoubleValue();
  } else if (options.Has("timeout") && options.Get("timeout").IsBoolean() &&
             !options.Get("timeout").As<Napi::Boolean>().Value()) {
    timeout_seconds = 0;
  }

  if (options.Has("wait") && options.Get("wait").IsBoolean() &&
      options.Get("wait").As<Napi::Boolean>().Value() &&
      (!options.Has("timeout") || timeout_seconds < 0)) {
    timeout_seconds = 5;
  }

  if (!options.Has("wait") && !options.Has("timeout")) {
    timeout_seconds = 10;
  }

  std::string open_url;
  if (options.Has("open") && options.Get("open").IsString()) {
    open_url = options.Get("open").As<Napi::String>().Utf8Value();
  }

  std::string sound_name;
  bool has_sound = false;
  bool default_sound = false;
  if (options.Has("sound")) {
    Napi::Value sound = options.Get("sound");
    if (sound.IsBoolean()) {
      if (sound.As<Napi::Boolean>().Value()) {
        has_sound = true;
        default_sound = true;
        sound_name = "Bottle";
      }
    } else if (sound.IsString()) {
      sound_name = sound.As<Napi::String>().Utf8Value();
      if (sound_name.rfind("Notification.", 0) == 0) {
        sound_name = "Bottle";
      }
      has_sound = !sound_name.empty();
    }
  }

  std::string content_image;
  if (options.Has("contentImage") && options.Get("contentImage").IsString()) {
    content_image = options.Get("contentImage").As<Napi::String>().Utf8Value();
  }

  if (!IsRunningInAppBundle()) {
    const std::string message =
        "UNUserNotificationCenter requires an app bundle (Electron app).";
    if (has_callback) {
      Napi::ThreadSafeFunction tsfn =
          Napi::ThreadSafeFunction::New(env, callback, "notify_callback", 0, 1);
      tsfn.BlockingCall([message](Napi::Env env, Napi::Function cb) {
        Napi::Value err = Napi::Error::New(env, message).Value();
        cb.Call({err, env.Undefined(), env.Undefined()});
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
    auto ctx = std::make_shared<NotificationContext>(
        Napi::ThreadSafeFunction::New(env, callback, "notify_callback", 0,
                                      1),
        open_url);
    std::lock_guard<std::mutex> lock(g_contexts_mutex);
    g_contexts[notify_id] = ctx;
  }

  UNMutableNotificationContent* content = [UNMutableNotificationContent new];
  content.title = title.empty() ? @"" : [NSString stringWithUTF8String:title.c_str()];
  if (!subtitle.empty()) {
    content.subtitle = [NSString stringWithUTF8String:subtitle.c_str()];
  }
  content.body = [NSString stringWithUTF8String:message.c_str()];

  NSMutableDictionary* user_info = [NSMutableDictionary dictionary];
  user_info[kNTNManagedNotificationKey] = @YES;
  if (!open_url.empty()) {
    user_info[kNTNOpenURLKey] = [NSString stringWithUTF8String:open_url.c_str()];
  }
  if (reply) {
    user_info[kNTNReplyKey] = @YES;
  }
  content.userInfo = user_info;

  if (has_sound) {
    if (default_sound) {
      content.sound = [UNNotificationSound defaultSound];
    } else {
      NSString* resolved_sound = [NSString stringWithUTF8String:sound_name.c_str()];
      if (IsBuiltInMacSoundName(sound_name) &&
          [resolved_sound pathExtension].length == 0) {
        resolved_sound = [resolved_sound stringByAppendingPathExtension:@"aiff"];
      }
      content.sound = [UNNotificationSound soundNamed:resolved_sound];
    }
  }

  if (!content_image.empty()) {
    NSURL* attachment_url = URLFromStringValue(content_image);
    NSError* attachment_error = nil;
    UNNotificationAttachment* attachment =
        [UNNotificationAttachment attachmentWithIdentifier:@"contentImage"
                                                       URL:attachment_url
                                                   options:nil
                                                     error:&attachment_error];
    if (attachment) {
      content.attachments = @[ attachment ];
    } else if (attachment_error) {
      TryCompleteWithError(
          notify_id,
          std::string([[attachment_error localizedDescription] UTF8String]));
      return env.Undefined();
    }
  }

  if (!action_titles.empty() || reply) {
    NSMutableArray<UNNotificationAction*>* actions = [NSMutableArray array];
    if (reply) {
      UNTextInputNotificationAction* reply_action =
          [UNTextInputNotificationAction
              actionWithIdentifier:@"reply"
                             title:@"Reply"
                           options:UNNotificationActionOptionForeground
              textInputButtonTitle:@"Send"
              textInputPlaceholder:@""];
      [actions addObject:reply_action];
    } else {
      for (const std::string& title_value : action_titles) {
        std::string action_id = MakeActionIdentifier(title_value);
        NSString* action_identifier =
            [NSString stringWithUTF8String:action_id.c_str()];
        NSString* action_label =
            [NSString stringWithUTF8String:title_value.c_str()];
        UNNotificationAction* action = [UNNotificationAction
            actionWithIdentifier:action_identifier
                           title:action_label
                         options:UNNotificationActionOptionForeground];
        [actions addObject:action];
      }
    }

    NSString* category_id =
        [NSString stringWithFormat:@"toasted_%@", request_id];
    UNNotificationCategory* category = [UNNotificationCategory
        categoryWithIdentifier:category_id
                       actions:actions
             intentIdentifiers:@[]
                       options:UNNotificationCategoryOptionCustomDismissAction];
    [center setNotificationCategories:[NSSet setWithObject:category]];
    content.categoryIdentifier = category_id;
  }

  UNNotificationRequest* request =
      [UNNotificationRequest requestWithIdentifier:request_id
                                           content:content
                                           trigger:nil];

  ScheduleTimeout(notify_id, timeout_seconds);

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
                                     } else {
                                       MarkDelivered(notify_id);
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
               } else {
                 MarkDelivered(notify_id);
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
