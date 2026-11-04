# -*- coding: utf-8 -*-
"""v1.0.81: openaiTranslate 支持 maxAttempts，超时 15s -> 30s，重试次数收敛"""
import io
import sys

PATH = "LiveCap.m"
src = io.open(PATH, encoding="utf-8").read()

REPLACEMENTS = []

# 1) 方法签名：加入 maxAttempts
REPLACEMENTS.append((
"""- (void)openaiTranslate:(NSString *)text sysPrompt:(NSString *)sysPrompt
               cacheKey:(NSString *)cacheKey
               apiKey:(NSString *)apiKey apiBase:(NSString *)apiBase
                  model:(NSString *)model
             completion:(void (^)(NSString *result))completion {
    [self openaiTranslate:text sysPrompt:sysPrompt cacheKey:cacheKey
                   apiKey:apiKey apiBase:apiBase model:model attempt:0 completion:completion];
}""",
"""- (void)openaiTranslate:(NSString *)text sysPrompt:(NSString *)sysPrompt
               cacheKey:(NSString *)cacheKey
               apiKey:(NSString *)apiKey apiBase:(NSString *)apiBase
                  model:(NSString *)model maxAttempts:(NSInteger)maxAttempts
             completion:(void (^)(NSString *result))completion {
    [self openaiTranslate:text sysPrompt:sysPrompt cacheKey:cacheKey
                   apiKey:apiKey apiBase:apiBase model:model
                  attempt:0 maxAttempts:maxAttempts completion:completion];
}"""))

# 2) 内部实现签名
REPLACEMENTS.append((
"""- (void)openaiTranslate:(NSString *)text sysPrompt:(NSString *)sysPrompt
               cacheKey:(NSString *)cacheKey
               apiKey:(NSString *)apiKey apiBase:(NSString *)apiBase
                  model:(NSString *)model attempt:(NSInteger)attempt
             completion:(void (^)(NSString *result))completion {""",
"""- (void)openaiTranslate:(NSString *)text sysPrompt:(NSString *)sysPrompt
               cacheKey:(NSString *)cacheKey
               apiKey:(NSString *)apiKey apiBase:(NSString *)apiBase
                  model:(NSString *)model attempt:(NSInteger)attempt maxAttempts:(NSInteger)maxAttempts
             completion:(void (^)(NSString *result))completion {"""))

# 3) 超时 15s -> 30s（实测网关慢模型要 29~40s，15s 必然超时）
REPLACEMENTS.append((
"""    req.HTTPBody = payload;
    req.timeoutInterval = 15.0;
""",
"""    req.HTTPBody = payload;
    // 超时放宽到 30s：实测网关慢模型单次要 29~40s，15s 必然 -1001 超时。
    // 但因为 v1.0.81 改成了并行竞速（MyMemory 同时在跑），慢的这一路超时
    // 也不会拖累整句 —— 快的那个早已返回。
    req.timeoutInterval = 30.0;
"""))

# 4) 重试次数收敛：attempt < 2 -> attempt < maxAttempts
REPLACEMENTS.append((
"""            if (retryable && attempt < 2) {
                NSTimeInterval delay = 0.8 * (attempt + 1);
                LCLogF(@"translate: openai retry in %.1fs (attempt %ld -> %ld)", delay, (long)attempt, (long)(attempt + 1));
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                               dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    [self openaiTranslate:text sysPrompt:sysPrompt cacheKey:cacheKey
                                   apiKey:apiKey apiBase:apiBase model:model
                                  attempt:attempt + 1 completion:completion];
                });
                return;
            }""",
"""            // 重试次数由调用方指定：竞速模式下 maxAttempts=1（即不重试），
            // 因为另一家厂商已经在并行跑了，重试只会白白放大延迟。
            if (retryable && attempt < maxAttempts) {
                NSTimeInterval delay = 0.8 * (attempt + 1);
                LCLogF(@"translate: openai retry in %.1fs (attempt %ld -> %ld)", delay, (long)attempt, (long)(attempt + 1));
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                               dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    [self openaiTranslate:text sysPrompt:sysPrompt cacheKey:cacheKey
                                   apiKey:apiKey apiBase:apiBase model:model
                                  attempt:attempt + 1 maxAttempts:maxAttempts completion:completion];
                });
                return;
            }"""))

# 5) 内部实现里写缓存的逻辑保留，但 openai 单独命中缓存时不应重复覆盖 —— 无需改

# 6) PAYLOAD / RAW 诊断日志改为节流（每次翻译打 3 行，量不大但可精简）
REPLACEMENTS.append((
"""        LCLogF(@"translate: PAYLOAD len=%lu head=[%@]", (unsigned long)payload.length, head);""",
"""        if (LCLogThrottled(@"payload", 15.0)) {
            LCLogF(@"translate: PAYLOAD len=%lu head=[%@]", (unsigned long)payload.length, head);
        }"""))

REPLACEMENTS.append((
"""            LCLogF(@"translate: RAW len=%lu head=[%@]", (unsigned long)data.length, head);""",
"""            if (LCLogThrottled(@"raw", 15.0)) {
                LCLogF(@"translate: RAW len=%lu head=[%@]", (unsigned long)data.length, head);
            }"""))

for old, new in REPLACEMENTS:
    if old not in src:
        print("ERROR: anchor not found:\n%s" % old[:160])
        sys.exit(1)
    src = src.replace(old, new, 1)

io.open(PATH, "w", encoding="utf-8", newline="\n").write(src)
print("OK applied %d replacements" % len(REPLACEMENTS))
