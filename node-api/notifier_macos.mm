#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

#include <atomic>
#include <mutex>
#include <napi.h>
#include <string>
#include <unordered_map>

@interface NTNNotificationDelegate : NSObject <NSUserNotificationCenterDelegate>
@end

namespace {

static NSString* const kNotifyIdKey = @"__toasted_id";

struct NotificationContext {
  Napi::ThreadSafeFunction tsfn;
  std::atomic_bool completed{false};
};

std::mutex g_contexts_mutex;
std::unordered_map<std::string, NotificationContext*> g_contexts;

NTNNotificationDelegate* g_delegate = nil;

static void EnsureDelegateInstalled() {
  if (!g_delegate) {
    g_delegate = [NTNNotificationDelegate new];
  }
  NSUserNotificationCenter* center = [NSUserNotificationCenter defaultUserNotificationCenter];
  center.delegate = g_delegate;
}

static bool TryComplete(const std::string& id, const std::string& activation_value) {
  NotificationContext* ctx = nullptr;
  {
    std::lock_guard<std::mutex> lock(g_contexts_mutex);
    auto it = g_contexts.find(id);
    if (it == g_contexts.end()) {
      return false;
    }
    ctx = it->second;
    if (ctx->completed.exchange(true)) {
      return false;
    }
    g_contexts.erase(it);
  }

  Napi::ThreadSafeFunction tsfn = ctx->tsfn;
  tsfn.BlockingCall([activation_value](Napi::Env env, Napi::Function cb) {
    Napi::Value err = env.Null();
    Napi::Value response = env.Null();
    Napi::Object metadata = Napi::Object::New(env);
    metadata.Set("activationValue", Napi::String::New(env, activation_value));
    cb.Call({err, response, metadata});
  });
  tsfn.Release();
  delete ctx;
  return true;
}

static std::string NewNotificationId() {
  NSString* uuid = [[NSUUID UUID] UUIDString];
  return std::string([uuid UTF8String]);
}

}  // namespace

@implementation NTNNotificationDelegate

- (BOOL)userNotificationCenter:(NSUserNotificationCenter*)center
       shouldPresentNotification:(NSUserNotification*)notification {
  return YES;
}

- (void)userNotificationCenter:(NSUserNotificationCenter*)center
        didActivateNotification:(NSUserNotification*)notification {
  NSString* notify_id = notification.userInfo[kNotifyIdKey];
  if (!notify_id) {
    return;
  }

  std::string activation_value = "activate";
  if (notification.activationType == NSUserNotificationActivationTypeActionButtonClicked) {
    NSString* action_title = notification.actionButtonTitle;
    if (action_title && [action_title length] > 0) {
      activation_value = std::string([action_title UTF8String]);
    } else {
      activation_value = "action";
    }
  } else if (notification.activationType == NSUserNotificationActivationTypeReplied) {
    activation_value = "replied";
  }

  TryComplete(std::string([notify_id UTF8String]), activation_value);
  [center removeDeliveredNotification:notification];
}

@end

static Napi::Value Notify(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();

  if (info.Length() < 1 || !info[0].IsObject()) {
    Napi::TypeError::New(env, "First argument must be an options object").ThrowAsJavaScriptException();
    return env.Null();
  }

  Napi::Object options = info[0].As<Napi::Object>();
  Napi::Function callback;
  bool has_callback = false;

  if (info.Length() >= 2) {
    if (!info[1].IsFunction()) {
      Napi::TypeError::New(env, "Second argument must be a function").ThrowAsJavaScriptException();
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
    Napi::TypeError::New(env, "Expected non-empty message option").ThrowAsJavaScriptException();
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

  EnsureDelegateInstalled();
  NSUserNotificationCenter* center = [NSUserNotificationCenter defaultUserNotificationCenter];

  NSUserNotification* notification = [NSUserNotification new];
  notification.title = [NSString stringWithUTF8String:title.c_str()];
  notification.informativeText = [NSString stringWithUTF8String:message.c_str()];

  if (!action_title.empty()) {
    notification.hasActionButton = YES;
    notification.actionButtonTitle = [NSString stringWithUTF8String:action_title.c_str()];
  }

  std::string notify_id = NewNotificationId();
  notification.userInfo = @{ kNotifyIdKey: [NSString stringWithUTF8String:notify_id.c_str()] };

  if (has_callback) {
    auto* ctx = new NotificationContext{
      Napi::ThreadSafeFunction::New(env, callback, "notify_callback", 0, 1)
    };
    std::lock_guard<std::mutex> lock(g_contexts_mutex);
    g_contexts[notify_id] = ctx;
  }

  [center scheduleNotification:notification];

  if (has_callback && timeout_seconds > 0) {
    dispatch_time_t when = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout_seconds * NSEC_PER_SEC));
    dispatch_after(when, dispatch_get_main_queue(), ^{
      if (TryComplete(notify_id, "timeout")) {
        [center removeDeliveredNotification:notification];
        [center removeScheduledNotification:notification];
      }
    });
  }

  return env.Undefined();
}

Napi::Object Init(Napi::Env env, Napi::Object exports) {
  exports.Set(Napi::String::New(env, "notify"), Napi::Function::New(env, Notify));
  return exports;
}

NODE_API_MODULE(notifier, Init)
