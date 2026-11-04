# -*- coding: utf-8 -*-
"""v1.0.81: 用并行竞速 + 精简 prompt 替换串行 fallback 翻译链路"""
import io
import sys

PATH = "LiveCap.m"

src = io.open(PATH, encoding="utf-8").read()

OLD_START = "    _inflight = YES;\n    NSString *target = [[LCConfig shared] targetLang];\n    NSString *sysPrompt = [NSString stringWithFormat:"
i = src.find(OLD_START)
if i < 0:
    print("ERROR: start anchor not found")
    sys.exit(1)

OLD_END = """        [self mymemoryTranslate:text targetLang:target cacheKey:cacheKey completion:proceed];
    }
}
"""
j = src.find(OLD_END, i)
if j < 0:
    print("ERROR: end anchor not found")
    sys.exit(1)
j += len(OLD_END)

NEW = '''    _inflight = YES;
    NSString *target = [[LCConfig shared] targetLang];

    // ===== prompt 精简（v1.0.81）=====
    // 实测（设备 → apihub.agnes-ai.cn 网关）：
    //   agnes-3.0-flash + 1401 字节长 prompt → 29~40s（必然超时）
    //   agnes-2.5-flash +  232 字节中 prompt → 0.96~7.6s（可用）
    // 长 prompt 不只是慢，还会显著抬高网关排队时间。
    // 这里保留最关键的三条约束（只输出译文 / 输入可能是脏片段要照翻 / 绝不回显英文），
    // 去掉示例和冗长规则，压到 ~230 字节。
    NSString *sysPrompt = [NSString stringWithFormat:
        @"Translate to %@. Output ONLY the translation: no quotes, no explanation. "
        @"The input may be a noisy speech-to-text fragment: infer the meaning and output Chinese. "
        @"NEVER echo the English input; the output MUST contain Chinese characters.",
        target];

    __weak typeof(self) weakSelf = self;
    [self raceTranslate:text sysPrompt:sysPrompt cacheKey:cacheKey target:target
             completion:^(NSString *result) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        dispatch_async(strongSelf->_queue, ^{
            strongSelf->_inflight = NO;
            if (comp) dispatch_async(dispatch_get_main_queue(), ^{ comp(result); });
            [strongSelf pumpQueue];
        });
    }];
}

// 译文有效性校验：模型对识别质量差的输入（乱码/短片段）常原样返回英文 ——
// 这不算翻译成功。必须与原文比对，且目标语言为中文时结果里必须含中文字符。
- (BOOL)isUsableTranslation:(NSString *)res forText:(NSString *)text {
    if (!res.length) return NO;
    NSString *norm = [res stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!norm.length) return NO;
    NSString *orig = [text stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([norm isEqualToString:orig]) return NO;
    NSString *dst = [[LCConfig shared] targetLang];
    if ([dst hasPrefix:@"zh"]) {
        BOOL hasCJK = NO;
        for (NSUInteger i = 0; i < norm.length; i++) {
            unichar ch = [norm characterAtIndex:i];
            if (ch >= 0x4E00 && ch <= 0x9FFF) { hasCJK = YES; break; }
        }
        if (!hasCJK) return NO;
    }
    return YES;
}

// ===== 并行竞速翻译（v1.0.81）=====
// 背景：串行 fallback 的致命问题是「等最慢的那家」。
//   旧顺序 agnes → mymemory → tencent，而 agnes 单次实测 29~40s，
//   串起来一句要 45s+，字幕永远追不上语音（实测画面停在第一句 51 秒）。
// 改成并行发出，谁先返回【有效译文】谁获胜，其余结果直接丢弃：
//   实测 agnes-2.5-flash 0.87~3.4s、MyMemory 1.25~2.4s，
//   竞速后整体延迟 = min(两者) ≈ 1s。
// 竞速天然提供了冗余：一家失败另一家顶上，不再需要靠重试放大延迟。
- (void)raceTranslate:(NSString *)text sysPrompt:(NSString *)sysPrompt
               cacheKey:(NSString *)cacheKey target:(NSString *)target
             completion:(void (^)(NSString *result))completion {
    NSString *apiKey = [[LCConfig shared] apiKey];
    NSString *apiBase = [[LCConfig shared] apiBase];
    NSString *model = [[LCConfig shared] model];

    // 参赛厂商
    NSMutableArray *providers = [NSMutableArray array];
    if (apiKey.length && apiBase.length) [providers addObject:@"agnes"];
    [providers addObject:@"mymemory"];               // 永远保留的免费兜底
    BOOL tencentDisabled = NO;
    @synchronized(self) { tencentDisabled = _tencentDisabled; }
    NSString *secretId = [[LCConfig shared] tencentSecretId];
    NSString *secretKey = [[LCConfig shared] tencentSecretKey];
    if (!tencentDisabled && secretId.length && secretKey.length) [providers addObject:@"tencent"];

    // 竞速状态：pending=未结束请求数，won=是否已有赢家
    NSMutableDictionary *state = [NSMutableDictionary dictionary];
    state[@"pending"] = @(providers.count);
    state[@"won"] = @NO;

    // 单个厂商的回调
    void (^onResult)(NSString *, NSString *) = ^(NSString *provider, NSString *res) {
        BOOL accept = NO;
        BOOL allFailed = NO;
        @synchronized (state) {
            BOOL won = [state[@"won"] boolValue];
            if (!won && res.length && [self isUsableTranslation:res forText:text]) {
                state[@"won"] = @YES;
                accept = YES;
            } else {
                if (res.length) {
                    LCLogF(@"translate: provider '%@' unusable (原文回显或无中文)", provider);
                } else {
                    LCLogF(@"translate: provider '%@' failed", provider);
                }
                NSInteger p = [state[@"pending"] integerValue] - 1;
                state[@"pending"] = @(p);
                // 所有厂商都失败 → 整句翻译失败
                if (p <= 0 && !won) allFailed = YES;
            }
        }
        if (accept) {
            @synchronized(self) {
                _cache[cacheKey] = res;
                if (_cache.count > 300) [_cache removeAllObjects];
            }
            LCLogF(@"translate: provider '%@' WON len=%lu", provider, (unsigned long)res.length);
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(res); });
        } else if (allFailed) {
            LCLogF(@"translate: race all failed text=[%@]", text);
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
        }
    };

    // 并行发出全部请求
    for (NSString *provider in providers) {
        NSString *p = [provider copy];
        if ([p isEqualToString:@"tencent"]) {
            LCLogF(@"translate: race -> tencent");
            [self tencentTranslate:text systemPrompt:sysPrompt cacheKey:cacheKey
                          secretId:secretId secretKey:secretKey
                       completion:^(NSString *r) { onResult(p, r); }];
        } else if ([p isEqualToString:@"agnes"]) {
            LCLogF(@"translate: race -> agnes model=%@", model);
            [self openaiTranslate:text sysPrompt:sysPrompt cacheKey:cacheKey
                          apiKey:apiKey apiBase:apiBase model:model maxAttempts:1
                       completion:^(NSString *r) { onResult(p, r); }];
        } else {
            LCLogF(@"translate: race -> mymemory");
            [self mymemoryTranslate:text targetLang:target cacheKey:cacheKey
                         completion:^(NSString *r) { onResult(p, r); }];
        }
    }
}
'''

src = src[:i] + NEW + src[j:]
io.open(PATH, "w", encoding="utf-8", newline="\n").write(src)
print("OK replaced %d chars -> %d chars" % (j - i, len(NEW)))
